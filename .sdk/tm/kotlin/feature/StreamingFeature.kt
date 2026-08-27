package KOTLINPACKAGE.feature

import java.util.NoSuchElementException
import java.util.function.IntConsumer
import java.util.function.Supplier

import KOTLINPACKAGE.core.Context
import KOTLINPACKAGE.core.Result
import KOTLINPACKAGE.core.SdkClient

// Streaming result support. For list-style operations it attaches a
// `result.stream` supplier yielding an iterator so callers can consume items
// incrementally. A `chunkSize` groups items into List batches; a `chunkDelay`
// (ms) paces delivery via the injectable `sleep`.
@Suppress("UNCHECKED_CAST")
class StreamingFeature : BaseFeature("streaming", "0.0.1", true) {

  private var client: SdkClient? = null
  private var options: MutableMap<String, Any?>? = null

  // Activity tracking (mirrors the ts client._streaming record).
  var opened = 0

  override fun init(ctx: Context, options: MutableMap<String, Any?>) {
    this.client = ctx.client
    this.options = options
    this.active = FeatureOptions.foptBool(options, "active", false)
  }

  override fun preResult(ctx: Context) {
    if (!this.active || !streamable(ctx)) {
      return
    }
    val result = ctx.result ?: return

    result.streaming = true
    result.stream = Supplier { iterate(result) }

    this.opened++
  }

  private fun iterate(result: Result): Iterator<Any?> {
    val chunkDelay = FeatureOptions.foptInt(this.options, "chunkDelay", 0)
    val chunkSize = FeatureOptions.foptInt(this.options, "chunkSize", 0)
    val sleep: IntConsumer = FeatureOptions.foptSleep(this.options)

    // Read lazily at stream() call time so downstream result processing
    // is reflected.
    val rd = result.resdata
    val items: List<Any?> = if (rd is List<*>) rd as List<Any?> else mutableListOf()

    return object : Iterator<Any?> {
      private var index = 0

      override fun hasNext(): Boolean {
        return index < items.size
      }

      override fun next(): Any? {
        if (!hasNext()) {
          throw NoSuchElementException()
        }
        if (chunkDelay > 0) {
          sleep.accept(chunkDelay)
        }
        if (chunkSize > 0) {
          val end = minOf(index + chunkSize, items.size)
          val batch = ArrayList(items.subList(index, end))
          index = end
          return batch
        }
        return items[index++]
      }
    }
  }

  private fun streamable(ctx: Context): Boolean {
    val opname = ctx.op.name
    var ops: List<String>? = FeatureOptions.foptStrList(this.options, "ops")
    if (ops == null) {
      ops = listOf("list")
    }
    for (o in ops) {
      if (o == opname) {
        return true
      }
    }
    return false
  }
}
