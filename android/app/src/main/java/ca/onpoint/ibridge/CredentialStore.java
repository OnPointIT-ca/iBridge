package ca.onpoint.ibridge;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.KeyStore;
import java.util.Arrays;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

/** Stores the connection and its bearer token as one authenticated encrypted value. */
public final class CredentialStore {
    private static final String PREFERENCES = "ibridge_credentials";
    private static final String BLOB = "credentials";
    private static final String KEYSTORE = "AndroidKeyStore";
    private static final String KEY_ALIAS = "ca.onpoint.ibridge.credentials.v1";
    private static final String TRANSFORMATION = "AES/GCM/NoPadding";
    private static final byte VERSION = 1;
    private static final int IV_LENGTH = 12;
    private static final int TAG_BITS = 128;
    private static final int MAX_FIELD_BYTES = 64 * 1024;
    private static final byte[] ASSOCIATED_DATA =
            "ca.onpoint.ibridge.credentials.v1".getBytes(StandardCharsets.UTF_8);
    // Serialize all instances so a clear cannot race a load or a save in this process.
    private static final Object LOCK = new Object();

    private final SharedPreferences preferences;

    public CredentialStore(Context context) {
        preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE);
    }

    public static final class Credentials {
        public final String origin;
        public final String token;

        private Credentials(String origin, String token) {
            this.origin = origin;
            this.token = token;
        }
    }

    /** Returns null only when no credentials have been saved. */
    public Credentials load() throws GeneralSecurityException, IOException {
        synchronized (LOCK) {
            String stored;
            try {
                stored = preferences.getString(BLOB, null);
            } catch (ClassCastException exception) {
                throw new IOException("Stored credentials are invalid", exception);
            }
            if (stored == null) {
                return null;
            }
            byte[] envelope;
            try {
                envelope = Base64.decode(stored, Base64.NO_WRAP);
            } catch (IllegalArgumentException exception) {
                throw new IOException("Stored credentials are invalid", exception);
            }
            if (envelope.length < 1 + IV_LENGTH + TAG_BITS / 8
                    || envelope[0] != VERSION) {
                throw new IOException("Stored credentials have an invalid format");
            }
            KeyStore keyStore = openKeyStore();
            SecretKey key = existingKey(keyStore);
            if (key == null) {
                throw new GeneralSecurityException("The credential encryption key is unavailable");
            }
            Cipher cipher = Cipher.getInstance(TRANSFORMATION);
            cipher.init(Cipher.DECRYPT_MODE, key,
                    new GCMParameterSpec(TAG_BITS, envelope, 1, IV_LENGTH));
            cipher.updateAAD(ASSOCIATED_DATA);
            byte[] plaintext = cipher.doFinal(envelope, 1 + IV_LENGTH,
                    envelope.length - 1 - IV_LENGTH);
            try (DataInputStream input = new DataInputStream(new ByteArrayInputStream(plaintext))) {
                String origin = readField(input);
                String token = readField(input);
                if (input.available() != 0) {
                    throw new IOException("Stored credentials have trailing data");
                }
                return new Credentials(origin, token);
            } finally {
                Arrays.fill(plaintext, (byte) 0);
            }
        }
    }

    public void save(String origin, String token) throws GeneralSecurityException, IOException {
        if (origin == null || token == null || origin.isEmpty() || token.isEmpty()) {
            throw new IllegalArgumentException("Origin and token must not be empty");
        }
        synchronized (LOCK) {
            byte[] plaintext;
            try (ByteArrayOutputStream bytes = new ByteArrayOutputStream();
                    DataOutputStream output = new DataOutputStream(bytes)) {
                writeField(output, origin);
                writeField(output, token);
                output.flush();
                plaintext = bytes.toByteArray();
            }
            try {
                KeyStore keyStore = openKeyStore();
                SecretKey key = existingKey(keyStore);
                if (key == null) {
                    KeyGenerator generator = KeyGenerator.getInstance(
                            KeyProperties.KEY_ALGORITHM_AES, KEYSTORE);
                    generator.init(new KeyGenParameterSpec.Builder(KEY_ALIAS,
                            KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                            .setKeySize(256)
                            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                            .setRandomizedEncryptionRequired(true)
                            .build());
                    key = generator.generateKey();
                }
                Cipher cipher = Cipher.getInstance(TRANSFORMATION);
                // AndroidKeyStore generates a fresh random nonce for every encryption.
                cipher.init(Cipher.ENCRYPT_MODE, key);
                cipher.updateAAD(ASSOCIATED_DATA);
                byte[] ciphertext = cipher.doFinal(plaintext);
                byte[] iv = cipher.getIV();
                if (iv.length != IV_LENGTH) {
                    throw new GeneralSecurityException("Unexpected encryption nonce length");
                }
                byte[] envelope = new byte[1 + iv.length + ciphertext.length];
                envelope[0] = VERSION;
                System.arraycopy(iv, 0, envelope, 1, iv.length);
                System.arraycopy(ciphertext, 0, envelope, 1 + iv.length, ciphertext.length);
                if (!preferences.edit().putString(BLOB,
                        Base64.encodeToString(envelope, Base64.NO_WRAP)).commit()) {
                    throw new IOException("Could not save credentials");
                }
            } finally {
                Arrays.fill(plaintext, (byte) 0);
            }
        }
    }

    /** Deletes the ciphertext and its encryption key, including after a preference write failure. */
    public void clear() throws GeneralSecurityException, IOException {
        synchronized (LOCK) {
            boolean removed = preferences.edit().remove(BLOB).commit();
            openKeyStore().deleteEntry(KEY_ALIAS);
            if (!removed) {
                throw new IOException("Could not remove stored credentials");
            }
        }
    }

    private static KeyStore openKeyStore() throws GeneralSecurityException, IOException {
        KeyStore keyStore = KeyStore.getInstance(KEYSTORE);
        keyStore.load(null);
        return keyStore;
    }

    private static SecretKey existingKey(KeyStore keyStore) throws GeneralSecurityException {
        java.security.Key key = keyStore.getKey(KEY_ALIAS, null);
        if (key == null) {
            return null;
        }
        if (!(key instanceof SecretKey)) {
            throw new GeneralSecurityException("The credential encryption key is invalid");
        }
        return (SecretKey) key;
    }

    private static void writeField(DataOutputStream output, String value) throws IOException {
        byte[] bytes = value.getBytes(StandardCharsets.UTF_8);
        try {
            if (bytes.length > MAX_FIELD_BYTES) {
                throw new IOException("Credential field is too large");
            }
            output.writeInt(bytes.length);
            output.write(bytes);
        } finally {
            Arrays.fill(bytes, (byte) 0);
        }
    }

    private static String readField(DataInputStream input) throws IOException {
        int length = input.readInt();
        if (length <= 0 || length > MAX_FIELD_BYTES || length > input.available()) {
            throw new IOException("Stored credential field is invalid");
        }
        byte[] bytes = new byte[length];
        try {
            input.readFully(bytes);
            return new String(bytes, StandardCharsets.UTF_8);
        } finally {
            Arrays.fill(bytes, (byte) 0);
        }
    }
}
