import macros

import tables, options

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

# TODO: clean this up
proc toBody*(body: string): seq[HTMLNode] {.gcsafe.} =
  return @[HTMLNode(kind: htmlnkText, text: body)]

proc toBody*(body: HTML): seq[HTMLNode] {.gcsafe.} =
  # if body has some <style> tag nested- move to root
  # echo "toBody: ", body
  
  var styles: seq[HTMLNode] = @[]
  var styleElementIds: seq[string] = @[]
  result = walk(body, proc(node: HTMLNode): Option[HTMLNode] =
    case node.kind
    of htmlnkElement:
      if node.tag == "style":
        if node.elementId notin styleElementIds:
          styles.add node
          styleElementIds.add node.elementId
        return none(HTMLNode)
    else:
      discard
    return some(node)
  )
  result = styles & result