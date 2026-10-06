package com.gravitycompile.gravix_cloud.rtc

import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

class EnginePluginLookupTest {
  private class Plugin(val name: String)

  @Test
  fun ownEngineInstanceWinsOverAReplacedSingleton() {
    val own = Plugin("ui engine")
    // a headless engine (foreground task) registered later and took the singleton
    val headless = Plugin("headless engine")
    assertSame(own, EnginePluginLookup.resolve({ own }, { headless }))
  }

  @Test
  fun fallsBackToTheSingletonWhenTheEngineHasNoInstance() {
    val shared = Plugin("shared")
    assertSame(shared, EnginePluginLookup.resolve<Plugin>({ null }, { shared }))
  }

  @Test
  fun fallsBackToTheSingletonWhenTheEngineLookupThrows() {
    val shared = Plugin("shared")
    assertSame(shared, EnginePluginLookup.resolve<Plugin>({ throw IllegalStateException("detached") }, { shared }))
  }

  @Test
  fun nullWhenNeitherIsAvailable() {
    assertNull(EnginePluginLookup.resolve<Plugin>({ null }, { null }))
  }
}
