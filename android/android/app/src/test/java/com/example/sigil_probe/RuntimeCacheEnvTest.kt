package com.example.sigil_probe

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class RuntimeCacheEnvTest {
    @Test
    fun controlledImportRootIsCacheDirChild() {
        val cache = File("/data/user/0/com.example.sigil_probe.foundationtest/cache")
        val root = com.example.sigil_probe.attachments.StagingRoots.controlledImport(cache.absolutePath)
        assertEquals(File(cache, "controlled_import").absolutePath, root)
        assertTrue(root.startsWith(cache.absolutePath + File.separator))
    }
}
