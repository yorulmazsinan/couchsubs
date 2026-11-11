// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.account

import android.app.Activity
import android.content.Context
import android.os.Bundle
import android.util.Log
import androidx.credentials.CredentialManager
import androidx.credentials.CustomCredential
import androidx.credentials.GetCredentialRequest
import com.couchsubs.mobile.BuildConfig
import com.google.android.libraries.identity.googleid.GetGoogleIdOption
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential
import com.google.firebase.FirebaseApp
import com.google.firebase.analytics.FirebaseAnalytics
import com.google.firebase.auth.EmailAuthProvider
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.auth.FirebaseUser
import com.google.firebase.auth.GoogleAuthProvider
import com.google.firebase.auth.OAuthProvider
import com.google.firebase.auth.userProfileChangeRequest
import com.google.firebase.crashlytics.FirebaseCrashlytics
import com.google.firebase.remoteconfig.FirebaseRemoteConfig
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.tasks.await

/**
 * Firebase'e tek giriş noktası. app/google-services.json yoksa Firebase hiç açılmaz ([available] false): ölçüm ve
 * çökme raporu sessizce atlanır, giriş ekranı "hesap özellikleri bu derlemede yok" der, uygulamanın geri kalanı çalışır.
 */
object Backend {
    private const val TAG = "CouchSubsBackend"
    @Volatile var available = false
        private set
    private var analytics: FirebaseAnalytics? = null

    fun init(context: Context) {
        available = try {
            FirebaseApp.getApps(context).isNotEmpty() || FirebaseApp.initializeApp(context) != null
        } catch (error: Exception) {
            Log.w(TAG, "Firebase yok", error)
            false
        }
        if (!available) return
        analytics = FirebaseAnalytics.getInstance(context)
        Account.start()
        RemoteFlags.start()
    }

    /** İzin değişince ölçüm ve çökme raporu açılır/kapanır (Consent Mode v2). */
    fun applyConsent(flags: ConsentFlags) {
        if (!available) return
        analytics?.setAnalyticsCollectionEnabled(flags.analyticsCollection)
        analytics?.setConsent(
            mapOf(
                FirebaseAnalytics.ConsentType.ANALYTICS_STORAGE to status(flags.analyticsStorage),
                FirebaseAnalytics.ConsentType.AD_STORAGE to status(flags.adStorage),
                FirebaseAnalytics.ConsentType.AD_USER_DATA to status(flags.adUserData),
                FirebaseAnalytics.ConsentType.AD_PERSONALIZATION to status(flags.adPersonalization),
            )
        )
        FirebaseCrashlytics.getInstance().setCrashlyticsCollectionEnabled(flags.crashReports)
    }

    private fun status(granted: Boolean) =
        if (granted) FirebaseAnalytics.ConsentStatus.GRANTED else FirebaseAnalytics.ConsentStatus.DENIED

    internal fun analyticsOrNull() = analytics

    fun recordError(error: Throwable) {
        if (available) FirebaseCrashlytics.getInstance().recordException(error)
    }
}

/**
 * Ürün olayları. Firebase'in ayrılmış adları (session_start, first_open…) kullanılamadığı için okuma oturumu
 * "subtitle_session_start/stop" adını taşır. Meta'ya yalnız izin varsa ve yalnız reklam ölçümü için gerekenler gider.
 */
object Telemetry {
    const val SIGN_UP = "sign_up"
    const val LOGIN = "login"
    const val PAYWALL_VIEW = "paywall_view"
    const val PURCHASE = "purchase"
    const val PACK_HIT = "pack_hit"
    const val SESSION_START = "subtitle_session_start"
    const val SESSION_STOP = "subtitle_session_stop"
    const val TV_CONNECTED = "tv_connected"

    fun event(name: String, vararg params: Pair<String, Any?>) {
        val analytics = Backend.analyticsOrNull() ?: return
        analytics.logEvent(name, Bundle().apply {
            for ((key, value) in params) when (value) {
                is String -> putString(key, value)
                is Int -> putLong(key, value.toLong())
                is Long -> putLong(key, value)
                is Double -> putDouble(key, value)
                is Boolean -> putString(key, value.toString())
                null -> {}
                else -> putString(key, value.toString())
            }
        })
        Ads.mirror(name, params.toMap())
    }

    fun screen(route: String) {
        val analytics = Backend.analyticsOrNull() ?: return
        analytics.logEvent(FirebaseAnalytics.Event.SCREEN_VIEW, Bundle().apply {
            putString(FirebaseAnalytics.Param.SCREEN_NAME, route)
            putString(FirebaseAnalytics.Param.SCREEN_CLASS, "Compose")
        })
    }
}

/** Remote Config: "ads_enabled" (varsayılan false). */
object RemoteFlags {
    val adsEnabled = MutableStateFlow(false)

    internal fun start() {
        val config = FirebaseRemoteConfig.getInstance()
        config.setDefaultsAsync(mapOf("ads_enabled" to false))
        config.fetchAndActivate().addOnCompleteListener { adsEnabled.value = config.getBoolean("ads_enabled") }
    }
}

/** Oturum açmış kullanıcı (Firebase Auth). */
data class AccountUser(val uid: String, val email: String?, val name: String?, val providers: List<String>, val emailVerified: Boolean) {
    val hasPassword get() = "password" in providers
}

class AccountException(val reason: Reason, cause: Throwable? = null) : Exception(reason.name, cause) {
    enum class Reason { UNAVAILABLE, INVALID_CREDENTIALS, EMAIL_IN_USE, WEAK_PASSWORD, RECENT_LOGIN_REQUIRED, NETWORK, CANCELLED, OTHER }
}

/** Firebase Auth: Google, e-posta/şifre, Apple (Firebase OAuth sağlayıcısıyla); profil ve hesap silme. */
object Account {
    private val state = MutableStateFlow<AccountUser?>(null)
    val user: StateFlow<AccountUser?> = state

    internal fun start() {
        FirebaseAuth.getInstance().addAuthStateListener { auth -> publish(auth.currentUser) }
    }

    private fun publish(user: FirebaseUser?) {
        state.value = user?.let { u -> AccountUser(u.uid, u.email, u.displayName, u.providerData.map { it.providerId }, u.isEmailVerified) }
        Subscriptions.identify(user?.uid)
    }

    private fun auth(): FirebaseAuth {
        if (!Backend.available) throw AccountException(AccountException.Reason.UNAVAILABLE)
        return FirebaseAuth.getInstance()
    }

    private suspend fun <T> guard(block: suspend () -> T): T = try {
        block()
    } catch (error: AccountException) {
        throw error
    } catch (error: Exception) {
        throw AccountException(classify(error), error)
    }

    private fun classify(error: Exception): AccountException.Reason = when (error) {
        is com.google.firebase.auth.FirebaseAuthWeakPasswordException -> AccountException.Reason.WEAK_PASSWORD
        is com.google.firebase.auth.FirebaseAuthUserCollisionException -> AccountException.Reason.EMAIL_IN_USE
        is com.google.firebase.auth.FirebaseAuthRecentLoginRequiredException -> AccountException.Reason.RECENT_LOGIN_REQUIRED
        is com.google.firebase.auth.FirebaseAuthInvalidCredentialsException,
        is com.google.firebase.auth.FirebaseAuthInvalidUserException -> AccountException.Reason.INVALID_CREDENTIALS
        is com.google.firebase.FirebaseNetworkException -> AccountException.Reason.NETWORK
        is androidx.credentials.exceptions.GetCredentialCancellationException -> AccountException.Reason.CANCELLED
        else -> AccountException.Reason.OTHER
    }

    suspend fun signUp(email: String, password: String, name: String) = guard {
        val result = auth().createUserWithEmailAndPassword(email.trim(), password).await()
        if (name.isNotBlank()) result.user?.updateProfile(userProfileChangeRequest { displayName = name.trim() })?.await()
        result.user?.sendEmailVerification()
        publish(auth().currentUser)
        Telemetry.event(Telemetry.SIGN_UP, "method" to "password")
    }

    suspend fun signIn(email: String, password: String) = guard {
        auth().signInWithEmailAndPassword(email.trim(), password).await()
        Telemetry.event(Telemetry.LOGIN, "method" to "password")
    }

    suspend fun resetPassword(email: String) = guard { auth().sendPasswordResetEmail(email.trim()).await() }

    /** google-services.json'dan gelen web istemci kimliği (Google ile giriş için); yoksa null. */
    fun googleClientId(context: Context): String? {
        val id = context.resources.getIdentifier("default_web_client_id", "string", context.packageName)
        return if (id == 0) null else context.getString(id)
    }

    suspend fun signInWithGoogle(activity: Activity) = guard {
        val clientId = googleClientId(activity) ?: throw AccountException(AccountException.Reason.UNAVAILABLE)
        val option = GetGoogleIdOption.Builder().setServerClientId(clientId).setFilterByAuthorizedAccounts(false).build()
        val credential = CredentialManager.create(activity).getCredential(activity, GetCredentialRequest.Builder().addCredentialOption(option).build()).credential
        if (credential !is CustomCredential || credential.type != GoogleIdTokenCredential.TYPE_GOOGLE_ID_TOKEN_CREDENTIAL)
            throw AccountException(AccountException.Reason.OTHER)
        val google = GoogleIdTokenCredential.createFrom(credential.data)
        val result = auth().signInWithCredential(GoogleAuthProvider.getCredential(google.idToken, null)).await()
        Telemetry.event(if (result.additionalUserInfo?.isNewUser == true) Telemetry.SIGN_UP else Telemetry.LOGIN, "method" to "google")
    }

    /** Apple ile giriş: Firebase konsolunda Apple sağlayıcısı açık olmalı (Hizmet kimliği, anahtar). */
    suspend fun signInWithApple(activity: Activity) = guard {
        val provider = OAuthProvider.newBuilder("apple.com").setScopes(listOf("email", "name")).build()
        val result = auth().pendingAuthResult?.await() ?: auth().startActivityForSignInWithProvider(activity, provider).await()
        Telemetry.event(if (result.additionalUserInfo?.isNewUser == true) Telemetry.SIGN_UP else Telemetry.LOGIN, "method" to "apple")
    }

    suspend fun updateName(name: String) = guard {
        val user = auth().currentUser ?: throw AccountException(AccountException.Reason.INVALID_CREDENTIALS)
        user.updateProfile(userProfileChangeRequest { displayName = name.trim() }).await()
        user.reload().await()
        publish(auth().currentUser)
    }

    /** Şifre değişikliği: önce mevcut şifreyle yeniden doğrulanır (Firebase yakın zamanda giriş ister). */
    suspend fun changePassword(current: String, new: String) = guard {
        val user = auth().currentUser ?: throw AccountException(AccountException.Reason.INVALID_CREDENTIALS)
        user.reauthenticate(EmailAuthProvider.getCredential(user.email ?: "", current)).await()
        user.updatePassword(new).await()
    }

    /** Yeni adrese doğrulama bağlantısı gider; tıklanınca e-posta değişir. */
    suspend fun changeEmail(newEmail: String, password: String?) = guard {
        val user = auth().currentUser ?: throw AccountException(AccountException.Reason.INVALID_CREDENTIALS)
        if (password != null) user.reauthenticate(EmailAuthProvider.getCredential(user.email ?: "", password)).await()
        user.verifyBeforeUpdateEmail(newEmail.trim()).await()
    }

    /** Sunucuya giden kimlik (paket indirme). */
    suspend fun idToken(forceRefresh: Boolean = false): String? =
        if (!Backend.available) null else FirebaseAuth.getInstance().currentUser?.getIdToken(forceRefresh)?.await()?.token

    /**
     * Firebase kullanıcısını siler. Şifreli hesapta önce [password] ile yeniden doğrulanır; Google/Apple hesabında son
     * giriş eskiyse RECENT_LOGIN_REQUIRED döner (ekran yeniden giriş ister).
     */
    suspend fun deleteUser(password: String?) = guard {
        val user = auth().currentUser ?: return@guard
        if (password != null && user.email != null) user.reauthenticate(EmailAuthProvider.getCredential(user.email!!, password)).await()
        user.delete().await()
    }

    fun signOut() {
        if (Backend.available) FirebaseAuth.getInstance().signOut()
        Subscriptions.identify(null)
    }

    /** Uygulama içinden çağrılan doğrulama (ana iş parçacığında değil). */
    val signedIn: Boolean get() = state.value != null

    val buildHasAccounts: Boolean get() = BuildConfig.HAS_FIREBASE
}
