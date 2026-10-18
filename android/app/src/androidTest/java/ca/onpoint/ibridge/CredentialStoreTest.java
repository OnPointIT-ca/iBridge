package ca.onpoint.ibridge;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotEquals;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertThrows;
import static org.junit.Assert.assertTrue;

import android.content.Context;
import android.content.SharedPreferences;
import android.util.Base64;

import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;

import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.KeyStore;
import java.util.Arrays;

@RunWith(AndroidJUnit4.class)
public final class CredentialStoreTest {
    private static final String ORIGIN = "https://bridge.example.test:8443";
    private static final String TOKEN = "test-only-credential-9db2f481";
    private static final String KEY_ALIAS = "ca.onpoint.ibridge.credentials.v1";
    private Context context;
    private SharedPreferences preferences;
    private CredentialStore store;

    @Before
    public void setUp() throws Exception {
        context = InstrumentationRegistry.getInstrumentation().getTargetContext();
        preferences = context.getSharedPreferences("ibridge_credentials", Context.MODE_PRIVATE);
        store = new CredentialStore(context);
        store.clear();
    }

    @After
    public void tearDown() throws Exception {
        store.clear();
    }

    @Test
    public void roundTripUsesEncryptedSingleBlobAndSurvivesNewInstance() throws Exception {
        assertNull(store.load());
        store.save(ORIGIN, TOKEN);

        CredentialStore.Credentials credentials = new CredentialStore(context).load();
        assertNotNull(credentials);
        assertEquals(ORIGIN, credentials.origin);
        assertEquals(TOKEN, credentials.token);
        assertEquals(1, preferences.getAll().size());
        String blob = preferences.getString("credentials", null);
        assertNotNull(blob);
        byte[] envelope = Base64.decode(blob, Base64.NO_WRAP);
        String raw = new String(envelope, StandardCharsets.ISO_8859_1);
        assertFalse(raw.contains(ORIGIN));
        assertFalse(raw.contains(TOKEN));
        assertTrue(keyStore().containsAlias(KEY_ALIAS));
        assertNull(keyStore().getKey(KEY_ALIAS, null).getEncoded());
    }

    @Test
    public void savingAgainUsesFreshNonce() throws Exception {
        store.save(ORIGIN, TOKEN);
        String first = preferences.getString("credentials", null);
        store.save(ORIGIN, TOKEN);
        String second = preferences.getString("credentials", null);
        assertNotEquals(first, second);
        byte[] firstEnvelope = Base64.decode(first, Base64.NO_WRAP);
        byte[] secondEnvelope = Base64.decode(second, Base64.NO_WRAP);
        assertFalse(Arrays.equals(Arrays.copyOfRange(firstEnvelope, 1, 13),
                Arrays.copyOfRange(secondEnvelope, 1, 13)));
        assertEquals(TOKEN, store.load().token);
    }

    @Test
    public void clearDeletesCiphertextAndKeyAndAllowsNewCredentials() throws Exception {
        store.save(ORIGIN, TOKEN);
        store.clear();
        assertNull(new CredentialStore(context).load());
        assertTrue(preferences.getAll().isEmpty());
        assertFalse(keyStore().containsAlias(KEY_ALIAS));

        store.save(ORIGIN, "replacement-test-token");
        assertEquals("replacement-test-token", store.load().token);
    }

    @Test
    public void changedCiphertextFailsAuthentication() throws Exception {
        store.save(ORIGIN, TOKEN);
        byte[] envelope = Base64.decode(preferences.getString("credentials", null), Base64.NO_WRAP);
        envelope[envelope.length - 1] ^= 1;
        assertTrue(preferences.edit().putString("credentials",
                Base64.encodeToString(envelope, Base64.NO_WRAP)).commit());
        assertThrows(GeneralSecurityException.class, store::load);
    }

    @Test
    public void malformedBlobIsRejected() {
        assertTrue(preferences.edit().putString("credentials", "invalid!base64").commit());
        assertThrows(IOException.class, store::load);
    }

    @Test
    public void missingKeyDoesNotGenerateReplacementOrReturnCredentials() throws Exception {
        store.save(ORIGIN, TOKEN);
        keyStore().deleteEntry(KEY_ALIAS);
        assertThrows(GeneralSecurityException.class, store::load);
        assertFalse(keyStore().containsAlias(KEY_ALIAS));
    }

    private static KeyStore keyStore() throws Exception {
        KeyStore keyStore = KeyStore.getInstance("AndroidKeyStore");
        keyStore.load(null);
        return keyStore;
    }
}
