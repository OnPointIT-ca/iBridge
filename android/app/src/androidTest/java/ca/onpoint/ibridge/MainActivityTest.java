package ca.onpoint.ibridge;

import static androidx.test.espresso.Espresso.onView;
import static androidx.test.espresso.action.ViewActions.click;
import static androidx.test.espresso.action.ViewActions.closeSoftKeyboard;
import static androidx.test.espresso.action.ViewActions.replaceText;
import static androidx.test.espresso.action.ViewActions.scrollTo;
import static androidx.test.espresso.assertion.ViewAssertions.matches;
import static androidx.test.espresso.matcher.ViewMatchers.isDisplayed;
import static androidx.test.espresso.matcher.ViewMatchers.withId;
import static androidx.test.espresso.matcher.ViewMatchers.withText;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import android.app.Activity;
import android.app.Application;
import android.content.Context;
import android.os.Bundle;
import android.os.Parcel;
import android.view.View;

import androidx.lifecycle.ViewModelProvider;
import androidx.test.core.app.ActivityScenario;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;

import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;

import java.nio.charset.StandardCharsets;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** Offline UI checks; these tests never submit an HTTPS connection. */
@RunWith(AndroidJUnit4.class)
public final class MainActivityTest {
    private static final String TOKEN = "instrumentation-test-token-rotation-723b13e4";
    private CredentialStore credentials;
    private Application application;

    @Before
    public void setUp() throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation().getTargetContext();
        credentials = new CredentialStore(context);
        credentials.clear();
        application = (Application) context.getApplicationContext();
    }

    @After
    public void tearDown() throws Exception {
        credentials.clear();
    }

    @Test
    public void httpOriginIsRejectedBeforeConnectingOrSavingCredentials() throws Exception {
        try (ActivityScenario<MainActivity> scenario = ActivityScenario.launch(MainActivity.class)) {
            awaitConnectionForm(scenario);
            onView(withId(R.id.bridge_address)).perform(replaceText("http://127.0.0.1:1"));
            onView(withId(R.id.bridge_token)).perform(replaceText(TOKEN), closeSoftKeyboard());
            onView(withText("Connect")).perform(scrollTo(), click());

            onView(withText("Use an HTTPS origin without credentials, a path, query, or fragment."))
                    .perform(scrollTo()).check(matches(isDisplayed()));
            onView(withId(R.id.bridge_token)).check(matches(withText(TOKEN)));
            scenario.onActivity(activity -> {
                BridgeViewModel model = new ViewModelProvider(activity).get(BridgeViewModel.class);
                assertFalse(model.busy);
                assertTrue(model.screen == BridgeViewModel.Screen.CONNECT);
            });
            assertNull(credentials.load());
        }
    }

    @Test
    public void tokenSurvivesRecreationWithoutEnteringSavedActivityState() throws Exception {
        try (ActivityScenario<MainActivity> scenario = ActivityScenario.launch(MainActivity.class)) {
            awaitConnectionForm(scenario);
            onView(withId(R.id.bridge_address)).perform(replaceText("https://bridge.example.test"));
            onView(withId(R.id.bridge_token)).perform(replaceText(TOKEN), closeSoftKeyboard());
            scenario.onActivity(activity -> {
                View token = activity.findViewById(R.id.bridge_token);
                assertFalse(token.isSaveEnabled());
                assertTrue(token.getImportantForAutofill() == View.IMPORTANT_FOR_AUTOFILL_NO);
            });

            SavedStateCapture capture = new SavedStateCapture();
            application.registerActivityLifecycleCallbacks(capture);
            try {
                scenario.recreate();
            } finally {
                application.unregisterActivityLifecycleCallbacks(capture);
            }

            onView(withId(R.id.bridge_address)).check(matches(withText("https://bridge.example.test")));
            onView(withId(R.id.bridge_token)).check(matches(withText(TOKEN)));
            assertNotNull("Recreation must exercise the actual saved-state callback", capture.serialized);
            assertFalse(contains(capture.serialized, TOKEN.getBytes(StandardCharsets.UTF_16LE)));
            assertFalse(contains(capture.serialized, TOKEN.getBytes(StandardCharsets.UTF_8)));
            assertNull(credentials.load());
        }
    }

    private static void awaitConnectionForm(ActivityScenario<MainActivity> scenario) throws Exception {
        CountDownLatch ready = new CountDownLatch(1);
        scenario.onActivity(activity -> {
            BridgeViewModel model = new ViewModelProvider(activity).get(BridgeViewModel.class);
            model.changes().observe(activity, ignored -> {
                if (!model.busy) ready.countDown();
            });
        });
        assertTrue("The initial credential lookup did not finish", ready.await(10, TimeUnit.SECONDS));
    }

    private static boolean contains(byte[] bytes, byte[] needle) {
        for (int start = 0; start <= bytes.length - needle.length; start++) {
            int offset = 0;
            while (offset < needle.length && bytes[start + offset] == needle[offset]) offset++;
            if (offset == needle.length) return true;
        }
        return false;
    }

    private static final class SavedStateCapture implements Application.ActivityLifecycleCallbacks {
        volatile byte[] serialized;

        @Override public void onActivitySaveInstanceState(Activity activity, Bundle outState) {
            if (!(activity instanceof MainActivity)) return;
            Parcel parcel = Parcel.obtain();
            try {
                parcel.writeBundle(outState);
                serialized = parcel.marshall();
            } finally {
                parcel.recycle();
            }
        }

        @Override public void onActivityCreated(Activity activity, Bundle savedInstanceState) { }
        @Override public void onActivityStarted(Activity activity) { }
        @Override public void onActivityResumed(Activity activity) { }
        @Override public void onActivityPaused(Activity activity) { }
        @Override public void onActivityStopped(Activity activity) { }
        @Override public void onActivityDestroyed(Activity activity) { }
    }
}
