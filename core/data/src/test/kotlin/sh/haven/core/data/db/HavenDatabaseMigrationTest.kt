package sh.haven.core.data.db

import androidx.room.Room
import androidx.room.testing.MigrationTestHelper
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Room migration tests for [HavenDatabase]. Each test materializes the
 * *previous* schema straight from the committed JSON under
 * `core/data/schemas` (via [MigrationTestHelper]), seeds rows at the old
 * shape, then reopens the file through `Room.databaseBuilder` with the
 * real migration registered — so the migration itself runs and the DAO
 * reads prove the new column exists with the right type and default.
 *
 * Opening through the builder (rather than the helper's
 * `runMigrationsAndValidate`) deliberately avoids depending on the
 * freshly generated schema JSON being packaged into test assets before
 * first build; the compiled Room implementation is authoritative.
 */
@RunWith(RobolectricTestRunner::class)
class HavenDatabaseMigrationTest {

    @get:Rule
    val helper = MigrationTestHelper(
        InstrumentationRegistry.getInstrumentation(),
        HavenDatabase::class.java,
    )

    @Test
    fun `migration 86 to 87 adds nullable hardwareAlias to ssh_keys`() {
        val dbName = "migration-test-86.db"
        helper.createDatabase(dbName, 86).apply {
            execSQL(
                """
                INSERT INTO ssh_keys (
                    id, label, keyType, privateKeyBytes,
                    publicKeyOpenSsh, fingerprintSha256, createdAt,
                    isEncrypted, biometricProtected, enabledForAuth
                ) VALUES (
                    'legacy-1', 'work laptop', 'ssh-ed25519', x'010203',
                    'ssh-ed25519 AAAA', 'SHA256:legacy', 42,
                    0, 0, 1
                )
                """.trimIndent()
            )
            close()
        }

        val db = Room.databaseBuilder(
            ApplicationProvider.getApplicationContext(),
            HavenDatabase::class.java,
            dbName,
        )
            .addMigrations(HavenDatabase.MIGRATION_86_87)
            .build()

        db.openHelper.writableDatabase // force open + migration
        try {
            runBlocking {
                val dao = db.sshKeyDao()

                // Pre-existing software rows migrate to hardwareAlias = NULL
                // (they are software keys by definition).
                assertNull(dao.getById("legacy-1")?.hardwareAlias)

                // A hardware-resident row round-trips its Android Keystore alias.
                dao.upsert(hardwareKey("hw-1", alias = "haven_hw_hw-1"))
                assertEquals("haven_hw_hw-1", dao.getById("hw-1")?.hardwareAlias)
            }
        } finally {
            db.close()
        }
    }

    private fun hardwareKey(id: String, alias: String) = sh.haven.core.data.db.entities.SshKey(
        id = id,
        label = id,
        keyType = "ecdsa-sha2-nistp256",
        // Storage convention: no local private material for hardware keys.
        privateKeyBytes = ByteArray(0),
        publicKeyOpenSsh = "ecdsa-sha2-nistp256 AAAA",
        fingerprintSha256 = "SHA256:$id",
        hardwareAlias = alias,
    )
}
