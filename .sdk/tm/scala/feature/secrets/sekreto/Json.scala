// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (scala/src/Json.scala)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// Minimal JSON support for sekreto.
//
// sekreto adds no third-party dependencies, so it carries just enough JSON
// to read a vault's answer and write the CLI's own line of output. It is
// deliberately not a general-purpose library.
//
// An `enum` rather than plain `Any`: a vault answering `null`, `false`, `0`
// and "no such key" means four different things, and a closed value model
// keeps them apart at compile time rather than by convention. `parse`
// returns `Option[Json]`, where `None` means "this text is not JSON" and
// `Some(Json.Null)` means "this text is the JSON literal null" - a
// distinction the callers of fetchjson need, since only the first is a
// malformed response.
//
// A port of typescript/src/Json.ts, which is canonical.

package com.voxgig.sekreto

import scala.collection.immutable.ListMap
import scala.util.control.NonFatal

/** Thrown while reading malformed JSON; never escapes `Json.parse`. */
private class JsonError(message: String) extends RuntimeException(message)

enum Json:

  case Null
  case Bool(value: Boolean)
  case Num(value: Double)
  case Str(value: String)
  case Arr(value: List[Json])
  case Obj(value: ListMap[String, Json])

  def asstr: Option[String] = this match
    case Str(value) => Some(value)
    case _          => None

  def asnum: Option[Double] = this match
    case Num(value) => Some(value)
    case _          => None

  def asarr: Option[List[Json]] = this match
    case Arr(value) => Some(value)
    case _          => None

  def asobj: Option[ListMap[String, Json]] = this match
    case Obj(value) => Some(value)
    case _          => None

  /** Walk nested objects; None the moment a step is not there. */
  def dig(keys: String*): Option[Json] =
    var at: Option[Json] = Some(this)

    for key <- keys do
      at = at.flatMap:
        case Obj(value) => value.get(key)
        case _          => None

    at

  /** This value as the text a caller would print, or None when there is no
    * value at all. A JSON null is "no value": every provider here treats it
    * as a miss rather than as the string "null".
    */
  def text: Option[String] = this match
    case Null        => None
    case Str(value)  => Some(value)
    case Num(value)  => Some(numstr(value))
    case Bool(value) => Some(if value then "true" else "false")
    case other       => Some(Json.stringify(other))

object Json:

  def str(value: String): Json = Str(value)

  def num(value: Double): Json = Num(value)

  def bool(value: Boolean): Json = Bool(value)

  def arr(entries: List[Json]): Json = Arr(entries)

  /** An object, in the order given: a payload's field order is signed. */
  def obj(entries: (String, Json)*): Json = Obj(ListMap.from(entries))

  /** Parse JSON text. None for anything unreadable - which the caller must
    * tell apart from a literal `null` body, since only the first means the
    * store could not answer coherently.
    */
  def parse(text: String): Option[Json] =
    if null == text || text.isEmpty then None
    else
      try
        val reader = Reader(text)
        reader.skip()
        val value = reader.value()
        reader.skip()
        if !reader.done then throw JsonError(s"sekreto: json: trailing content at ${reader.at}")
        Some(value)
      catch case NonFatal(_) => None

  /** Render a value as compact JSON. */
  def stringify(value: Json): String =
    val out = StringBuilder()
    write(value, out)
    out.toString

  /** Render a string as a JSON string literal, quotes included. */
  def quote(text: String): String =
    val out = StringBuilder("\"")

    for ch <- text do
      ch match
        case '"'  => out.append("\\\"")
        case '\\' => out.append("\\\\")
        case '\n' => out.append("\\n")
        case '\r' => out.append("\\r")
        case '\t' => out.append("\\t")
        case _ =>
          if 0x20 > ch.toInt then out.append("\\u%04x".format(ch.toInt))
          else out.append(ch)

    out.append('"').toString

  private def write(value: Json, out: StringBuilder): Unit = value match
    case Null        => out.append("null")
    case Bool(entry) => out.append(if entry then "true" else "false")
    case Num(entry)  => out.append(numstr(entry))
    case Str(entry)  => out.append(quote(entry))
    case Arr(entries) =>
      out.append('[')
      for (entry, index) <- entries.zipWithIndex do
        if 0 < index then out.append(',')
        write(entry, out)
      out.append(']')
    case Obj(entries) =>
      out.append('{')
      var first = true
      for (key, entry) <- entries do
        if !first then out.append(',')
        first = false
        out.append(quote(key)).append(':')
        write(entry, out)
      out.append('}')

  private class Reader(val text: String):

    var at: Int = 0

    def done: Boolean = at >= text.length

    def skip(): Unit =
      while !done && text(at).isWhitespace do at += 1

    def value(): Json =
      if done then throw JsonError("sekreto: json: unexpected end")

      text(at) match
        case '{' => obj()
        case '[' => arr()
        case '"' => Json.Str(str())
        case 't' => word("true"); Json.Bool(true)
        case 'f' => word("false"); Json.Bool(false)
        case 'n' => word("null"); Json.Null
        case _   => num()

    def word(want: String): Unit =
      if !text.startsWith(want, at) then throw JsonError(s"sekreto: json: bad literal at $at")
      at += want.length

    def obj(): Json =
      var out = ListMap.empty[String, Json]
      at += 1 // {

      skip()
      if !done && '}' == text(at) then
        at += 1
        return Json.Obj(out)

      var running = true
      while running do
        skip()
        val key = str()
        skip()

        if done || ':' != text(at) then throw JsonError(s"sekreto: json: expected ':' at $at")
        at += 1

        skip()
        out = out.updated(key, value())
        skip()

        if done then throw JsonError("sekreto: json: unterminated object")
        if ',' == text(at) then at += 1
        else if '}' == text(at) then
          at += 1
          running = false
        else throw JsonError(s"sekreto: json: expected ',' or '}' at $at")

      Json.Obj(out)

    def arr(): Json =
      val out = scala.collection.mutable.ListBuffer.empty[Json]
      at += 1 // [

      skip()
      if !done && ']' == text(at) then
        at += 1
        return Json.Arr(out.toList)

      var running = true
      while running do
        skip()
        out += value()
        skip()

        if done then throw JsonError("sekreto: json: unterminated array")
        if ',' == text(at) then at += 1
        else if ']' == text(at) then
          at += 1
          running = false
        else throw JsonError(s"sekreto: json: expected ',' or ']' at $at")

      Json.Arr(out.toList)

    def str(): String =
      if done || '"' != text(at) then throw JsonError(s"sekreto: json: expected string at $at")
      at += 1

      val out = StringBuilder()

      while !done do
        val ch = text(at)
        at += 1

        if '"' == ch then return out.toString

        if '\\' != ch then out.append(ch)
        else
          if done then throw JsonError("sekreto: json: unterminated string")
          val escape = text(at)
          at += 1
          escape match
            case '"'  => out.append('"')
            case '\\' => out.append('\\')
            case '/'  => out.append('/')
            case 'b'  => out.append('\b')
            case 'f'  => out.append('\f')
            case 'n'  => out.append('\n')
            case 'r'  => out.append('\r')
            case 't'  => out.append('\t')
            case 'u' =>
              if at + 4 > text.length then throw JsonError("sekreto: json: bad unicode escape")
              out.append(Integer.parseInt(text.substring(at, at + 4), 16).toChar)
              at += 4
            case other => throw JsonError(s"sekreto: json: bad escape [$other] at $at")

      throw JsonError("sekreto: json: unterminated string")

    def num(): Json =
      val start = at

      if !done && ('-' == text(at) || '+' == text(at)) then at += 1

      while !done && (text(at).isDigit || '.' == text(at) || 'e' == text(at) ||
          'E' == text(at) || '-' == text(at) || '+' == text(at))
      do at += 1

      val span = text.substring(start, at)

      span.toDoubleOption match
        case Some(value) => Json.Num(value)
        case None        => throw JsonError(s"sekreto: json: bad number [$span] at $start")

/** The same reads on an optional value, so a provider can walk a response
  * body - which is `Option[Json]`, because a store may not have answered
  * with JSON at all - without unwrapping at every step.
  */
extension (self: Option[Json])

  def dig(keys: String*): Option[Json] = self.flatMap(_.dig(keys*))

  def text: Option[String] = self.flatMap(_.text)

  def asstr: Option[String] = self.flatMap(_.asstr)

  def asnum: Option[Double] = self.flatMap(_.asnum)

  def asarr: Option[List[Json]] = self.flatMap(_.asarr)

  def asobj: Option[ListMap[String, Json]] = self.flatMap(_.asobj)

/** Render a number the way every other port does: a whole number has no
  * fractional tail, so a JSON `1` read back and printed stays `1`.
  */
private[sekreto] def numstr(value: Double): String =
  if value.isNaN || value.isInfinite then "null"
  else if value == value.toLong.toDouble && 9007199254740992.0 > math.abs(value) then
    value.toLong.toString
  else value.toString
