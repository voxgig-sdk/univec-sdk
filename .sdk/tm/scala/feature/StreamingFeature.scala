package SCALAPACKAGE.feature

import java.util.{ArrayList, List => JList, Map => JMap}
import SCALAPACKAGE.core.{Context, Result, SdkClient}

// Streaming result support. For list-style operations it attaches a
// `result.stream` supplier yielding an iterator so callers can consume
// items incrementally instead of materialising the whole list at once. A
// `chunkSize` groups items into List<Object> batches when set; a
// `chunkDelay` (ms) paces delivery via the injectable `sleep` for offline
// tests. Each stream() call yields a fresh iterator.
class StreamingFeature extends BaseFeature("streaming", "0.0.1", true) {

  private var client: SdkClient = null
  private var options: JMap[String, Object] = null

  // Activity tracking (mirrors the ts client._streaming record).
  var opened: Int = 0

  override def init(ctx: Context, options: JMap[String, Object]): Unit = {
    this.client = ctx.client
    this.options = options
    this.active = FeatureOptions.foptBool(options, "active", false)
  }

  override def preResult(ctx: Context): Unit = {
    if (!this.active || !streamable(ctx)) {
      return
    }
    val result = ctx.result
    if (result == null) {
      return
    }

    result.streaming = true
    val s: java.util.function.Supplier[java.util.Iterator[Object]] = () => iterate(result)
    result.stream = s

    this.opened += 1
  }

  private def iterate(result: Result): java.util.Iterator[Object] = {
    val chunkDelay = FeatureOptions.foptInt(this.options, "chunkDelay", 0)
    val chunkSize = FeatureOptions.foptInt(this.options, "chunkSize", 0)
    val sleep = FeatureOptions.foptSleep(this.options)

    // Read lazily at stream() call time so downstream result processing
    // is reflected.
    val items: JList[Object] = result.resdata match {
      case l: JList[_] => l.asInstanceOf[JList[Object]]
      case _ => new ArrayList[Object]()
    }

    new java.util.Iterator[Object] {
      private var index = 0

      override def hasNext(): Boolean = {
        index < items.size()
      }

      override def next(): Object = {
        if (!hasNext()) {
          throw new java.util.NoSuchElementException()
        }
        if (chunkDelay > 0) {
          sleep.accept(chunkDelay)
        }
        if (chunkSize > 0) {
          val end = Math.min(index + chunkSize, items.size())
          val batch = new ArrayList[Object](items.subList(index, end))
          index = end
          return batch
        }
        val r = items.get(index)
        index += 1
        r
      }
    }
  }

  private def streamable(ctx: Context): Boolean = {
    var opname = ""
    if (ctx.op != null) {
      opname = ctx.op.name
    }
    var ops = FeatureOptions.foptStrList(this.options, "ops")
    if (ops == null) {
      ops = java.util.List.of("list")
    }
    val it = ops.iterator()
    while (it.hasNext) {
      if (it.next().equals(opname)) {
        return true
      }
    }
    false
  }
}
