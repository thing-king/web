import macros

import tables, options, sequtils, strutils, algorithm

import pkg/html



const ELEMENT_RENAMES = [
  ("box", "div")
].toTable
proc toElementName*(renamedName: string): string =
  if renamedName in ELEMENT_RENAMES:
    return ELEMENT_RENAMES[renamedName]
  return renamedName

proc concat*(node: NimNode, other: NimNode): NimNode =
  if node.kind == nnkEmpty:
    return other
  return nnkInfix.newTree(
    ident("&"),
    node,
    other
  )

# TODO: rename `toBody` to something more fitting
proc toBody*(body: string, key: string): seq[HTMLNode] {.gcsafe.} =
  return @[HTMLNode(kind: htmlnkText, text: body)]

proc toBody*(body: HTML, key: string): seq[HTMLNode] {.gcsafe.} =
  return body

template toBody*(prc: untyped, keys: string): seq[HTMLNode] =
  toBody(prc(key = keys), keys)



# proc toBody*(body: var HTML, key: string): seq[HTMLNode] {.gcsafe.} =
#   filterEmptyStylesInPlace(body)
#   return body

# template toBody*(prc: untyped, key: string): seq[HTMLNode] =
#   var result = prc(key)
#   toBody(result, key)

proc getAttr*[T](opt: Option[T]): T =
  if opt.isSome:
    return opt.get
  else:
    return ""
proc getAttr*[T](opt: T): T = opt

proc getAttr*(value: bool): string =
  if value:
    return "true"
  return ""

import pkg/css
proc getAttr*(value: Styles): string =
  return $value


macro attachToWindow*(key: untyped, value: untyped) =
  if key.kind != nnkStrLit:
    error("Expected a string literal", key)
  let keyStr = key.strVal

  if value.kind != nnkIdent:
    error("Expected an identifier", value)
  let valueStr = value.strVal

  let emitStr = "window." & keyStr & " = `" & valueStr & "`;"

  result = quote do:
    {.emit: `emitStr`}