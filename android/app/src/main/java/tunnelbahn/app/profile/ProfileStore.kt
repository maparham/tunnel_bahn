package tunnelbahn.app.profile

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import kotlinx.serialization.json.Json

/**
 * Persists profiles. Non-secret fields go to plain prefs as JSON; private key material
 * is split out into a [SecretStore] (encrypted at rest) and never written to the plain
 * JSON, per the security constraint.
 */
class ProfileStore internal constructor(
    private val prefs: SharedPreferences,
    private val secrets: SecretStore,
) {
    constructor(context: Context) : this(
        context.getSharedPreferences(PROFILES_FILE, Context.MODE_PRIVATE),
        EncryptedSecretStore(context),
    )

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    fun save(p: Profile) {
        secrets.put(sshKeyId(p.id), p.sshPrivateKeyPem)
        secrets.put(wgKeyId(p.id), p.wgPrivateKey)
        secrets.put(wgPskId(p.id), p.wgPresharedKey)

        val scrubbed = p.copy(sshPrivateKeyPem = "", wgPrivateKey = "", wgPresharedKey = "")
        prefs.edit()
            .putString(profileKey(p.id), json.encodeToString(Profile.serializer(), scrubbed))
            .putStringSet(INDEX_KEY, ids() + p.id)
            .apply()
    }

    fun load(id: String): Profile? {
        val raw = prefs.getString(profileKey(id), null) ?: return null
        val scrubbed = json.decodeFromString(Profile.serializer(), raw)
        return scrubbed.copy(
            sshPrivateKeyPem = secrets.get(sshKeyId(id)).orEmpty(),
            wgPrivateKey = secrets.get(wgKeyId(id)).orEmpty(),
            wgPresharedKey = secrets.get(wgPskId(id)).orEmpty(),
        )
    }

    fun all(): List<Profile> = ids().mapNotNull { load(it) }

    fun delete(id: String) {
        secrets.remove(sshKeyId(id))
        secrets.remove(wgKeyId(id))
        secrets.remove(wgPskId(id))
        val e = prefs.edit()
            .remove(profileKey(id))
            .putStringSet(INDEX_KEY, ids() - id)
        if (prefs.getString(SELECTED_KEY, null) == id) e.remove(SELECTED_KEY)
        e.apply()
    }

    /** The profile the Home screen acts on. Falls back to the first stored profile so
     *  Home always has something to show once any profile exists. */
    fun selectedId(): String? = prefs.getString(SELECTED_KEY, null)?.takeIf { load(it) != null }
        ?: ids().firstOrNull()

    fun setSelectedId(id: String) {
        prefs.edit().putString(SELECTED_KEY, id).apply()
    }

    private fun ids(): Set<String> = prefs.getStringSet(INDEX_KEY, emptySet())!!.toSet()

    private companion object {
        const val PROFILES_FILE = "tb_profiles"
        const val INDEX_KEY = "ids"
        const val SELECTED_KEY = "selectedId"
        fun profileKey(id: String) = "profile.$id"
        fun sshKeyId(id: String) = "$id.sshKey"
        fun wgKeyId(id: String) = "$id.wgKey"
        fun wgPskId(id: String) = "$id.wgPsk"
    }
}

/** Secret storage abstraction so tests can bypass the Android Keystore. */
interface SecretStore {
    fun put(key: String, value: String)
    fun get(key: String): String?
    fun remove(key: String)
}

/** Production secret store: EncryptedSharedPreferences under a Keystore-wrapped AES key. */
class EncryptedSecretStore(context: Context) : SecretStore {
    private val prefs: SharedPreferences = run {
        val masterKey = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        EncryptedSharedPreferences.create(
            context,
            "tb_secrets",
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    override fun put(key: String, value: String) {
        prefs.edit().putString(key, value).apply()
    }

    override fun get(key: String): String? = prefs.getString(key, null)

    override fun remove(key: String) {
        prefs.edit().remove(key).apply()
    }
}
