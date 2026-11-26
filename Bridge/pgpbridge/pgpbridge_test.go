package pgpbridge

import (
	"bytes"
	"strings"
	"testing"
)

func mustKey(t *testing.T, name string) (priv, pub []byte) {
	t.Helper()
	priv, err := GenerateKey(name)
	if err != nil {
		t.Fatal(err)
	}
	pub, err = PublicKey(priv)
	if err != nil {
		t.Fatal(err)
	}
	return priv, pub
}

func TestRoundTripThreeRecipients(t *testing.T) {
	senderPriv, senderPub := mustKey(t, "sender")
	rcpts := NewRecipients()
	var privs [][]byte
	for _, n := range []string{"a", "b", "c"} {
		priv, pub := mustKey(t, n)
		privs = append(privs, priv)
		if err := rcpts.Add(pub); err != nil {
			t.Fatal(err)
		}
	}
	if rcpts.Count() != 3 {
		t.Fatalf("count = %d", rcpts.Count())
	}
	msg := []byte("Καλημέρα from Epistoli")
	ct, err := EncryptAndSign(msg, rcpts, senderPriv)
	if err != nil {
		t.Fatal(err)
	}
	for i, priv := range privs {
		pt, err := DecryptAndVerify(ct, priv, senderPub)
		if err != nil {
			t.Fatalf("recipient %d: %v", i, err)
		}
		if !bytes.Equal(pt, msg) {
			t.Fatalf("recipient %d: plaintext mismatch", i)
		}
	}
}

func TestNonRecipientCannotDecrypt(t *testing.T) {
	senderPriv, senderPub := mustKey(t, "sender")
	_, pub := mustKey(t, "a")
	outsiderPriv, _ := mustKey(t, "outsider")
	r := NewRecipients()
	_ = r.Add(pub)
	ct, _ := EncryptAndSign([]byte("hi"), r, senderPriv)
	if _, err := DecryptAndVerify(ct, outsiderPriv, senderPub); err == nil || !strings.HasPrefix(err.Error(), ErrPrefixDecrypt) {
		t.Fatalf("want decrypt error, got %v", err)
	}
}

func TestWrongSignerRejected(t *testing.T) {
	senderPriv, _ := mustKey(t, "sender")
	_, impostorPub := mustKey(t, "impostor")
	priv, pub := mustKey(t, "a")
	r := NewRecipients()
	_ = r.Add(pub)
	ct, _ := EncryptAndSign([]byte("hi"), r, senderPriv)
	if _, err := DecryptAndVerify(ct, priv, impostorPub); err == nil || !strings.HasPrefix(err.Error(), ErrPrefixSignature) {
		t.Fatalf("want signature error, got %v", err)
	}
}

func TestTamperedDetachedSignatureRejected(t *testing.T) {
	priv, pub := mustKey(t, "signer")
	data := []byte("the envelope")
	sig, err := SignDetached(data, priv)
	if err != nil {
		t.Fatal(err)
	}
	if err := VerifyDetached(data, sig, pub); err != nil {
		t.Fatalf("valid signature rejected: %v", err)
	}
	tamperedData := append([]byte{}, data...)
	tamperedData[0] ^= 1
	if err := VerifyDetached(tamperedData, sig, pub); err == nil {
		t.Fatal("tampered data accepted")
	}
	tamperedSig := append([]byte{}, sig...)
	tamperedSig[len(tamperedSig)-5] ^= 0xff
	if err := VerifyDetached(data, tamperedSig, pub); err == nil {
		t.Fatal("tampered signature accepted")
	}
}

func TestTamperedCiphertextRejected(t *testing.T) {
	senderPriv, senderPub := mustKey(t, "sender")
	priv, pub := mustKey(t, "a")
	r := NewRecipients()
	_ = r.Add(pub)
	ct, _ := EncryptAndSign([]byte("hello there, this is long enough"), r, senderPriv)
	ct[len(ct)-10] ^= 0xff
	if _, err := DecryptAndVerify(ct, priv, senderPub); err == nil {
		t.Fatal("tampered ciphertext accepted")
	}
}

func TestArmorRoundTripAndFingerprint(t *testing.T) {
	priv, pub := mustKey(t, "me")
	armored, err := ArmorPublicKey(priv)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(armored, "-----BEGIN PGP PUBLIC KEY BLOCK-----") {
		t.Fatal("not an armoured public key")
	}
	if strings.Contains(armored, "PRIVATE") {
		t.Fatal("armoured export contains private material")
	}
	imported, err := ImportArmoredPublicKey(armored)
	if err != nil {
		t.Fatal(err)
	}
	fp1, _ := Fingerprint(pub)
	fp2, _ := Fingerprint(imported)
	fp3, _ := Fingerprint(priv)
	if fp1 != fp2 || fp1 != fp3 || len(fp1) != 40 {
		t.Fatalf("fingerprints differ or wrong length: %s %s %s", fp1, fp2, fp3)
	}
}

func TestImportRejectsPrivateKey(t *testing.T) {
	priv, _ := mustKey(t, "me")
	k, _ := parsePrivate(priv)
	armoredPriv, err := k.Armor()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := ImportArmoredPublicKey(armoredPriv); err == nil {
		t.Fatal("private key imported as a contact key")
	}
}

func TestImportPublicKeyBinary(t *testing.T) {
	priv, pub := mustKey(t, "me")
	imported, err := ImportPublicKey(pub)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(imported, pub) {
		t.Fatal("public key did not round-trip byte for byte")
	}
	if _, err := ImportPublicKey(priv); err == nil || !strings.HasPrefix(err.Error(), ErrPrefixKey) {
		t.Fatalf("private key imported as a contact key: %v", err)
	}
	if _, err := ImportPublicKey([]byte("not a key")); err == nil {
		t.Fatal("garbage accepted")
	}
}

func TestEncryptRequiresRecipients(t *testing.T) {
	priv, _ := mustKey(t, "me")
	if _, err := EncryptAndSign([]byte("x"), NewRecipients(), priv); err == nil {
		t.Fatal("encrypted to nobody")
	}
}

func TestLibraryVersion(t *testing.T) {
	if LibraryVersion() != "3.5.2" {
		t.Fatalf("unexpected GopenPGP version %s", LibraryVersion())
	}
}
