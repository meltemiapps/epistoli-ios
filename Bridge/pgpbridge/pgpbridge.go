// Package pgpbridge is the narrow OpenPGP surface the app uses, built on GopenPGP v3.
// It is compiled into an xcframework with gomobile (see scripts/build_gopenpgp.sh), so every
// exported signature uses only gomobile-compatible types: []byte, string, int, error and
// pointers to exported structs.
//
// Keys cross the bridge as binary OpenPGP packets (unarmored). Private keys are never
// passphrase-locked here: the app protects them with the Keychain.
package pgpbridge

import (
	"fmt"
	"strings"
	"time"

	"github.com/ProtonMail/gopenpgp/v3/constants"
	"github.com/ProtonMail/gopenpgp/v3/crypto"
)

// Error message prefixes the Swift side matches on. Keep them stable.
const (
	ErrPrefixSignature = "pgpbridge: signature"
	ErrPrefixDecrypt   = "pgpbridge: decrypt"
	ErrPrefixKey       = "pgpbridge: key"
)

// Default profile: EdDSA + Curve25519 (v4 keys), the most widely implemented modern choice.
var pgp = crypto.PGP()

func keyErr(format string, args ...any) error {
	return fmt.Errorf(ErrPrefixKey+": "+format, args...)
}

func parsePrivate(b []byte) (*crypto.Key, error) {
	k, err := crypto.NewKey(b)
	if err != nil {
		return nil, keyErr("cannot parse private key: %v", err)
	}
	if !k.IsPrivate() {
		return nil, keyErr("expected a private key")
	}
	unlocked, err := k.IsUnlocked()
	if err != nil || !unlocked {
		return nil, keyErr("private key is locked")
	}
	return k, nil
}

func parsePublic(b []byte) (*crypto.Key, error) {
	k, err := crypto.NewKey(b)
	if err != nil {
		return nil, keyErr("cannot parse public key: %v", err)
	}
	if k.IsPrivate() {
		return k.ToPublic()
	}
	return k, nil
}

// GenerateKey creates a new Curve25519 identity key and returns it as binary private key packets.
func GenerateKey(name string) ([]byte, error) {
	k, err := pgp.KeyGeneration().AddUserId(name, "").New().GenerateKey()
	if err != nil {
		return nil, keyErr("generate: %v", err)
	}
	return k.Serialize()
}

// PublicKey returns the binary public key for a private (or public) key.
func PublicKey(key []byte) ([]byte, error) {
	k, err := parsePublic(key)
	if err != nil {
		return nil, err
	}
	return k.GetPublicKey()
}

// Fingerprint returns the key's fingerprint as lowercase hex.
func Fingerprint(key []byte) (string, error) {
	k, err := crypto.NewKey(key)
	if err != nil {
		return "", keyErr("cannot parse key: %v", err)
	}
	return strings.ToLower(k.GetFingerprint()), nil
}

// ArmorPublicKey exports the public part of a key as an ASCII-armoured block.
func ArmorPublicKey(key []byte) (string, error) {
	k, err := parsePublic(key)
	if err != nil {
		return "", err
	}
	return k.GetArmoredPublicKey()
}

// ImportArmoredPublicKey parses an armoured public key and returns binary public key packets.
// It rejects private keys (a contact must never send one) and keys that cannot encrypt and verify.
func ImportArmoredPublicKey(armored string) ([]byte, error) {
	k, err := crypto.NewKeyFromArmored(armored)
	if err != nil {
		return nil, keyErr("cannot parse armoured key: %v", err)
	}
	if k.IsPrivate() {
		return nil, keyErr("refusing to import a private key")
	}
	now := time.Now().Unix()
	if !k.CanEncrypt(now) || !k.CanVerify(now) {
		return nil, keyErr("key cannot encrypt and verify (expired, revoked or wrong usage)")
	}
	return k.GetPublicKey()
}

// ImportPublicKey parses binary public key packets received from someone else (for example in a
// contact code). Like ImportArmoredPublicKey it rejects private keys and keys that cannot encrypt
// and verify, and it returns the key re-serialised as public packets only.
func ImportPublicKey(publicKey []byte) ([]byte, error) {
	k, err := crypto.NewKey(publicKey)
	if err != nil {
		return nil, keyErr("cannot parse key: %v", err)
	}
	if k.IsPrivate() {
		return nil, keyErr("refusing to import a private key")
	}
	now := time.Now().Unix()
	if !k.CanEncrypt(now) || !k.CanVerify(now) {
		return nil, keyErr("key cannot encrypt and verify (expired, revoked or wrong usage)")
	}
	return k.GetPublicKey()
}

// Recipients collects public keys to encrypt to.
type Recipients struct {
	ring *crypto.KeyRing
}

// NewRecipients returns an empty recipient list.
func NewRecipients() *Recipients {
	ring, _ := crypto.NewKeyRing(nil)
	return &Recipients{ring: ring}
}

// Add appends a binary public key.
func (r *Recipients) Add(publicKey []byte) error {
	k, err := parsePublic(publicKey)
	if err != nil {
		return err
	}
	return r.ring.AddKey(k)
}

// Count is the number of keys added.
func (r *Recipients) Count() int {
	return r.ring.CountEntities()
}

// EncryptAndSign encrypts plaintext to every recipient and signs it with signingKey.
// The result is a binary OpenPGP message.
func EncryptAndSign(plaintext []byte, recipients *Recipients, signingKey []byte) ([]byte, error) {
	if recipients == nil || recipients.Count() == 0 {
		return nil, keyErr("no recipients")
	}
	signer, err := parsePrivate(signingKey)
	if err != nil {
		return nil, err
	}
	enc, err := pgp.Encryption().Recipients(recipients.ring).SigningKey(signer).New()
	if err != nil {
		return nil, err
	}
	msg, err := enc.Encrypt(plaintext)
	if err != nil {
		return nil, err
	}
	return msg.Bytes(), nil
}

// DecryptAndVerify decrypts a binary message with decryptionKey and requires a valid
// signature from verificationKey. Any signature problem (missing, wrong signer, tampered)
// is an error with ErrPrefixSignature; the plaintext is never returned in that case.
func DecryptAndVerify(ciphertext []byte, decryptionKey []byte, verificationKey []byte) ([]byte, error) {
	dk, err := parsePrivate(decryptionKey)
	if err != nil {
		return nil, err
	}
	vk, err := parsePublic(verificationKey)
	if err != nil {
		return nil, err
	}
	dec, err := pgp.Decryption().DecryptionKey(dk).VerificationKey(vk).New()
	if err != nil {
		return nil, err
	}
	res, err := dec.Decrypt(ciphertext, crypto.Bytes)
	if err != nil {
		return nil, fmt.Errorf(ErrPrefixDecrypt+": %v", err)
	}
	if sigErr := res.SignatureError(); sigErr != nil {
		return nil, fmt.Errorf(ErrPrefixSignature+": %v", sigErr)
	}
	return res.Bytes(), nil
}

// SignDetached returns a binary detached signature over data.
func SignDetached(data []byte, signingKey []byte) ([]byte, error) {
	signer, err := parsePrivate(signingKey)
	if err != nil {
		return nil, err
	}
	s, err := pgp.Sign().SigningKey(signer).Detached().New()
	if err != nil {
		return nil, err
	}
	return s.Sign(data, crypto.Bytes)
}

// VerifyDetached checks a binary detached signature. It returns nil only for a valid signature.
func VerifyDetached(data []byte, signature []byte, verificationKey []byte) error {
	vk, err := parsePublic(verificationKey)
	if err != nil {
		return err
	}
	v, err := pgp.Verify().VerificationKey(vk).New()
	if err != nil {
		return err
	}
	res, err := v.VerifyDetached(data, signature, crypto.Bytes)
	if err != nil {
		return fmt.Errorf(ErrPrefixSignature+": %v", err)
	}
	if sigErr := res.SignatureError(); sigErr != nil {
		return fmt.Errorf(ErrPrefixSignature+": %v", sigErr)
	}
	return nil
}

// LibraryVersion reports the GopenPGP version compiled in.
func LibraryVersion() string {
	return constants.Version
}
