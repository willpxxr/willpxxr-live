use anyhow::{Context, Result, bail};
use base64::Engine;
use chacha20poly1305::aead::{Aead, Generate, KeyInit};
use chacha20poly1305::{XChaCha20Poly1305, XNonce};

const NONCE_LEN: usize = 24;

pub struct Key(XChaCha20Poly1305);

impl Key {
    pub fn from_bytes(bytes: [u8; 32]) -> Self {
        Self(XChaCha20Poly1305::new((&bytes).into()))
    }

    pub fn from_env() -> Result<Self> {
        let raw = std::env::var("VAULT_ENCRYPTION_KEY").context("VAULT_ENCRYPTION_KEY not set")?;
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(raw.trim())
            .context("VAULT_ENCRYPTION_KEY must be base64")?;
        let bytes: [u8; 32] = bytes.try_into().map_err(|v: Vec<u8>| {
            anyhow::anyhow!(
                "VAULT_ENCRYPTION_KEY must decode to 32 bytes (got {})",
                v.len()
            )
        })?;
        Ok(Self::from_bytes(bytes))
    }

    pub fn encrypt(&self, plaintext: &[u8]) -> Result<Vec<u8>> {
        let nonce = chacha20poly1305::XNonce::generate();
        let ct = self
            .0
            .encrypt(&nonce, plaintext)
            .map_err(|_| anyhow::anyhow!("encrypt failed"))?;
        let mut out = Vec::with_capacity(NONCE_LEN + ct.len());
        out.extend_from_slice(nonce.as_slice());
        out.extend_from_slice(&ct);
        Ok(out)
    }

    pub fn decrypt(&self, blob: &[u8]) -> Result<Vec<u8>> {
        if blob.len() < NONCE_LEN {
            bail!("ciphertext too short");
        }
        let (nonce, ct) = blob.split_at(NONCE_LEN);
        self.0
            .decrypt(&XNonce::try_from(nonce).expect("nonce length"), ct)
            .map_err(|_| anyhow::anyhow!("decrypt failed"))
    }

    pub fn encrypt_string(&self, s: &str) -> Result<Vec<u8>> {
        self.encrypt(s.as_bytes())
    }

    pub fn decrypt_string(&self, blob: &[u8]) -> Result<String> {
        String::from_utf8(self.decrypt(blob)?).context("decrypted token is not utf-8")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_key() -> Key {
        Key::from_bytes([7u8; 32])
    }

    #[test]
    fn roundtrip() {
        let key = test_key();
        let blob = key.encrypt_string("lpat_secret_value").unwrap();
        assert_ne!(blob, b"lpat_secret_value");
        assert_eq!(key.decrypt_string(&blob).unwrap(), "lpat_secret_value");
    }

    #[test]
    fn unique_nonces() {
        let key = test_key();
        let a = key.encrypt_string("same").unwrap();
        let b = key.encrypt_string("same").unwrap();
        assert_ne!(a, b);
    }

    #[test]
    fn tampered_ciphertext_fails() {
        let key = test_key();
        let mut blob = key.encrypt_string("secret").unwrap();
        let last = blob.len() - 1;
        blob[last] ^= 0xff;
        assert!(key.decrypt(&blob).is_err());
    }
}
