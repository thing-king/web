import macros, tables, options, strutils

import web/util
export util

import pkg/css
import pkg/html

export css
export html

const DO_VALIDATE = false
const DO_LOG = false


proc excludeKey*(html: HTML, key: string): HTML =
  return html.filter(HTMLNodeFilter(proc(node: HTMLNode): bool =
    if node.kind != htmlnkElement:
      return false
    if not node.attributes.hasKey("element-id"):
      return false
    return node.attributes["element-id"] == key
  ))

proc excludeAttribute*(html: HTML, name: string, value: string): HTML =
  return html.filter(HTMLNodeFilter(proc(node: HTMLNode): bool =
    if node.kind != htmlnkElement:
      return false
    if not node.attributes.hasKey(name):
      return false
    return node.attributes[name] == value
  ))
proc excludeAttribute*(html: HTML, name: string): HTML =
  return html.filter(HTMLNodeFilter(proc(node: HTMLNode): bool =
    if node.kind != htmlnkElement:
      return false
    return node.attributes.hasKey(name)
  ))
proc excludeName*(html: HTML, name: string): HTML =
  return html.excludeAttribute("name", name)


const seperator*: string = "══════════════════════════════════════════════════"
proc log(msgs: varargs[string]) {.inline} =
  if not DO_LOG:
    return
  echo "[LOG] ", msgs.join(" | ")
proc logOn(condition: bool, msgs: varargs[string]) =
  if not DO_LOG:
    return
  if condition:
    echo "[LOGGED ON] ", seperator
    echo "[LOGGED ON] " & msgs.join("\n")

proc runtimeValidatePropertyValue*(name: string, value: string): string {.gcsafe.} =
  if not DO_VALIDATE:
    return value
  if not validatePropertyName(name).valid:
    raise newException(ValueError, "Invalid property name: " & name)
  let validation = css.validatePropertyValue(name, value)
  if not validation.valid:
    raise newException(ValueError, "Invalid property value: " & value & "\n" & validation.errors.join("\n"))
  return value

when defined(js):
  # import thing/dom
  import jsffi
  type CustomEvent* = ref object
    detail*: JsObject

# Elements that should not contain any body content
const VOID_ELEMENTS = @[
  "area", "base", "br", "col", "embed", "hr", "img", "input", 
  "link", "meta", "param", "source", "track", "wbr"
]


proc toTableRef*[K, V](pairs: openArray[(K, V)]): TableRef[K, V] =
  result = new(Table[K, V])
  for pair in pairs:
    result[pair[0]] = pair[1]
proc newTableRef*[K, V](pairs: openArray[(K, V)]): TableRef[K, V] =
  result = toTableRef(pairs)
proc newTableRef*[K, V](): TableRef[K, V] =
  result = new(Table[K, V])

proc fixVoidElementsWithStyles*(nodes: seq[HTMLNode], componentName: string = "", isTopLevel: bool = true): seq[HTMLNode] =
  result = newSeqOfCap[HTMLNode](nodes.len)

  for node in nodes:
    if node.kind == htmlnkElement:
      if node.tag in VOID_ELEMENTS and node.children.len > 0:
        # Process children first
        for child in node.children:
          if child.kind == htmlnkElement and child.tag == "style":
            # Check if style tag has any content (non-empty text nodes)
            var hasContent = false
            for styleChild in child.children:
              if styleChild.kind == htmlnkText and styleChild.text.strip().len > 0:
                hasContent = true
                break
            
            # Only add style elements that have content
            if hasContent:
              # Only set component-name on style elements if they don't have one AND we're at top level
              if componentName.len > 0 and isTopLevel and (not child.attributes.hasKey("component-name") or child.attributes["component-name"] == nil or child.attributes["component-name"] == ""):
                child.attributes["component-name"] = componentName
              result.add(child)
          else:
            raise newException(ValueError, "Void element '" & node.tag & "' cannot contain content other than styles")

        # Share the attributes reference instead of copying
        let strippedVoidNode = new(HTMLNode)
        strippedVoidNode.kind = htmlnkElement
        strippedVoidNode.tag = node.tag
        strippedVoidNode.attributes = node.attributes  # Share reference!
        strippedVoidNode.children = @[]
        
        # Build component name chain for void elements
        if componentName.len > 0 and isTopLevel:
          let existingName = if strippedVoidNode.attributes.hasKey("component-name") and strippedVoidNode.attributes["component-name"] != nil and strippedVoidNode.attributes["component-name"] != "": 
            strippedVoidNode.attributes["component-name"] 
          else: 
            ""
          strippedVoidNode.attributes["component-name"] = if existingName != "": 
            componentName & "," & existingName 
          else: 
            componentName
        result.add(strippedVoidNode)
      else:
        # For non-void elements, also share references
        let processedNode = new(HTMLNode)
        processedNode.kind = node.kind
        case node.kind:
        of htmlnkElement:
          processedNode.tag = node.tag
          processedNode.attributes = node.attributes  # Share reference!
          if node.children.len > 0:
            # Recursive call with isTopLevel = false to prevent overwriting nested component names
            processedNode.children = fixVoidElementsWithStyles(node.children, componentName, false)
          
          # Check if this is an empty style tag and skip it
          if processedNode.tag == "style":
            var hasContent = false
            for styleChild in processedNode.children:
              if styleChild.kind == htmlnkText and styleChild.text.strip().len > 0:
                hasContent = true
                break
            if not hasContent:
              continue  # Skip adding this empty style tag
              
        of htmlnkText:
          processedNode.text = node.text
        
        # Build component name chain for regular elements
        if componentName.len > 0 and isTopLevel and node.kind == htmlnkElement:
          let existingName = if processedNode.attributes.hasKey("component-name") and processedNode.attributes["component-name"] != nil and processedNode.attributes["component-name"] != "": 
            processedNode.attributes["component-name"] 
          else: 
            ""
          processedNode.attributes["component-name"] = if existingName != "": 
            componentName & "," & existingName 
          else: 
            componentName
        result.add(processedNode)
    else:
      result.add(node)  # Text nodes - no copying needed

type WebResponse = tuple[body: NimNode, eventHandlers: NimNode]
proc handleWeb*(inputBody: NimNode, thingUuid: string, thisUuid: string): WebResponse =
  var topElementId = thingUuid & "_" & thisUuid & "_dsl"

  # echo "HANDLING WEB WITH UUID"
  # echo thingUuid
  # echo thisUuid

  # let (doc, body) = computeStyles("element", inputBody)
  var body = inputBody


  type
    StyleResultKind = enum
      srkRUNTIME, srkCOMPILE_TIME

    StyleResult = object
      isQuoted: bool = false
      case kind: StyleResultKind
      of srkRUNTIME:
        style: NimNode
      of srkCOMPILE_TIME:
        properties: seq[WrittenDocumentNode]
        rules: seq[WrittenDocumentNode]

    Result = object
      styleResult: Option[StyleResult] = none(StyleResult)

      node: NimNode
      attributeName: string = ""
      attributeValue: NimNode
      isQuotedAttribute: bool = false


  var elementCount = 0
  proc uniqueElementId(): int =
    elementCount += 1
    return elementCount
  proc createComponentInstanceId(): NimNode =
    let index = uniqueElementId()
    let componentId = topElementId & "-" & $index
    return nnkInfix.newTree(
      ident("&"),
      nnkInfix.newTree(
        ident("&"),
        ident("key"),
        newStrLitNode("__")
      ),
      newStrLitNode(componentId)
    )

  let eventHandlers = newStmtList()

  proc createTextElement(strLit: NimNode): NimNode
  proc createElement(tagName: string, attributes: Table[string, NimNode], styles: seq[StyleResult], rawChildren: seq[NimNode], isTopLevel: bool, standaloneStyle: bool = false): NimNode =
    # add "element-id" attribute
    let index = uniqueElementId()
    var elementId = topElementId
    # if not isTopLevel:
    elementId &= "-" & $index
    
    let elementIdNode = nnkInfix.newTree(
      ident("&"),
      nnkInfix.newTree(
        ident("&"),
        ident("key"),
        newStrLitNode("__")
      ),
      newStrLitNode(elementId)
    )


    var fields = @[
      newTree(nnkExprColonExpr,
        newIdentNode("kind"),
        newIdentNode("htmlnkElement")
      ),
      newTree(nnkExprColonExpr,
        newIdentNode("tag"),
        newStrLitNode(if standaloneStyle: "style" else: tagName)
      )
    ]
    var modAttributes = attributes
    # assign "element-id" attribute
    modAttributes["element-id"] = elementIdNode

    var children = rawChildren

    var standaloneStyleContent: NimNode = newEmptyNode()
    if styles.len > 0:
      var stylesAttribute: NimNode = newEmptyNode()
      var classAttribute: NimNode = newEmptyNode()
      for styleResult in styles:
        case styleResult.kind
        of srkRUNTIME:
          let styleValue = nnkCall.newTree(
            ident("toStylesAttribute"),
            styleResult.style
          )
          if stylesAttribute.kind == nnkEmpty:
            stylesAttribute = styleValue
          else:
            stylesAttribute = nnkInfix.newTree(
              ident("&"),
              nnkInfix.newTree(
                ident("&"),
                stylesAttribute,
                newStrLitNode("; ")
              ),
              styleValue
            )
          
          let classValue = nnkCall.newTree(
            ident("toClassAttribute"),
            styleResult.style,
            elementIdNode
          )
          if classAttribute.kind == nnkEmpty:
            classAttribute = classValue
          else:
            classAttribute = nnkInfix.newTree(
              ident("&"),
              nnkInfix.newTree(
                ident("&"),
                classAttribute,
                newStrLitNode(" ")
              ),
              classValue
            )
          let styleElementValue = nnkCall.newTree(
            ident("toStylesElement"),
            styleResult.style,
            elementIdNode
          )
          if not standaloneStyle:
            let styleElement = createElement("style", initTable[string, NimNode](), @[], @[
              createTextElement(
                styleElementValue
              )
            ], isTopLevel)
            children.insert(styleElement, 0)
          else:
            if standaloneStyleContent.kind == nnkEmpty:
              standaloneStyleContent = styleElementValue
            else:
              standaloneStyleContent = nnkInfix.newTree(
                ident("&"),
                nnkInfix.newTree(
                  ident("&"),
                  standaloneStyleContent,
                  newStrLitNode(" ")
                ),
                styleElementValue
              )

        of srkCOMPILE_TIME:
          let properties = styleResult.properties
          let styleValue = properties.toStylesAttribute()
          if styleValue.kind != nnkEmpty:
            if stylesAttribute.kind == nnkEmpty:
              stylesAttribute = styleValue
            else:
              stylesAttribute = nnkInfix.newTree(
                ident("&"),
                nnkInfix.newTree(
                  ident("&"),
                  stylesAttribute,
                  newStrLitNode("; ")
                ),
                styleValue
              )
          let rules = styleResult.rules
          let classValue = rules.toClassAttribute(elementIdNode)
          if classValue.kind != nnkEmpty:
            if classAttribute.kind == nnkEmpty:
              classAttribute = classValue
            else:
              classAttribute = nnkInfix.newTree(
                ident("&"),
                nnkInfix.newTree(
                  ident("&"),
                  classAttribute,
                  newStrLitNode(" ")
                ),
                classValue
              )
          let stylesheet = rules.toStylesElement(elementIdNode)
          if stylesheet.kind != nnkEmpty:
            if not standaloneStyle:
              let styleElement = createElement("style", initTable[string, NimNode](), @[], @[
                createTextElement(
                  stylesheet
                )
              ], isTopLevel)
              children.insert(styleElement, 0)
            else:
              if standaloneStyleContent.kind == nnkEmpty:
                standaloneStyleContent = stylesheet
              else:
                standaloneStyleContent = nnkInfix.newTree(
                  ident("&"),
                  nnkInfix.newTree(
                    ident("&"),
                    standaloneStyleContent,
                    newStrLitNode(" ")
                  ),
                  stylesheet
                )

      # Add style attributes
      if stylesAttribute.kind != nnkEmpty:
        modAttributes["style"] = stylesAttribute
      if classAttribute.kind != nnkEmpty:
        modAttributes["class"] = classAttribute
    if standaloneStyle and standaloneStyleContent.kind != nnkEmpty:
      children.insert(createTextElement(standaloneStyleContent), 0)
    # echo "Creating element: " & tagName & " with id: " & elementId
    
    var tuples = newTree(nnkBracket)
    for key, rawValue in modAttributes:
      var value = rawValue
      if value.kind == nnkStrLit and value.strVal.startsWith("window.dispatchEvent(") and not value.strVal.startsWith("window.dispatchEvent(\""): 
        let eventName = key & "_" & elementId
        let handlerName = value.strVal.split("(")[1].split(")")[0]
        let handlerIdent = ident(handlerName)
        # let handlerIdent = ident("doOnContextMenu")
        # value = newStrLitNode("window.dispatchEvent(new Event('" & eventName & "'))")
        # value = newStrLitNode("(function(e) {  window['" & eventName & "'] = e; window.dispatchEvent(new Event('" & eventName & "'));  })(event)")
        # value = newStrLitNode("(function(e) {  e.type = 'test'; window.dispatchEvent(e);  })(event)")
        value = newStrLitNode("(function(e) {  window.dispatchEvent(new CustomEvent('" & eventName & "', { detail: { originalEvent: e } } ))  })(event)")
        let eventNameStrLit = newStrLitNode(eventName)
        
        # echo "HANDELR IDENT: " & handlerIdent.strVal
        let procName = "on" & eventName.replace(":", "z")
        let event = ident("event")
        
        eventhandlers.add nnkCall.newTree(
          nnkDotExpr.newTree(
            ident("window"),
            ident("addEventListener")
          ),
          eventNameStrLit,
          nnkLambda.newTree(
            newEmptyNode(),
            newEmptyNode(),
            newEmptyNode(),
            nnkFormalParams.newTree(
              newEmptyNode(),
              nnkIdentDefs.newTree(
                event,
                ident("Event"),
                newEmptyNode()
              )
            ),
            newEmptyNode(),
            newEmptyNode(),
            quote do:
              # get detail.originalEvent from event
              let customEvent = cast[JsObject](`event`)
              let detail = customEvent["detail"]
              let originalEventObject = detail["originalEvent"]
              let originalEvent = cast[Event](originalEventObject)
              # echo "Got event: " & originalEvent.repr
              `handlerIdent`(originalEvent)
          )
        )

        
      if value.kind == nnkIdent:
        value = nnkCall.newTree(
          ident("getAttr"),
          value
        )
      
      tuples.add(
        newTree(nnkTupleConstr, 
          newStrLitNode(key), 
          value
        )
      )


    if tuples.len > 0:
      var attrsTable = newTree(
        nnkDotExpr,
        newCall(
          newIdentNode("@"),
          tuples
        ),
        newIdentNode("toTableRef")
      )
      
      fields.add(
        newTree(nnkExprColonExpr,
          newIdentNode("attributes"),
          attrsTable
        )
      )


    # Add children if present
    if children.len > 0:
      # Create a call to @[] constructor to ensure we get a seq
      var childrenSeq: NimNode
      var map: seq[(bool, NimNode)] = @[]
      for child in children:
        if child.kind == nnkCall and child[0].strVal == "toBody":
          map.add((true, child))
        else:
          map.add((false, child))
      
      for item in map:
        let (isSeq, child) = item
        # echo "GOT: " & $isSeq
        # echo child.repr
        if isSeq:
          if childrenSeq == nil:
            childrenSeq = child
          else:
            childrenSeq = newTree(
              nnkInfix,
              ident("&"),
              childrenSeq,
              child,
            )
        else:
          if childrenSeq == nil:
            childrenSeq = newTree(nnkPrefix, ident("@"), newTree(nnkBracket, child))
          elif childrenSeq.kind == nnkInfix:
            if childrenSeq[2].kind != nnkPrefix:
              childrenSeq = newTree(
                nnkInfix,
                ident("&"),
                childrenSeq,
                newTree(nnkPrefix, ident("@"), newTree(nnkBracket, child)),
              )
            else:
              childrenSeq[2][1].add(child)
          else:
            childrenSeq = newTree(
              nnkInfix,
              ident("&"),
              childrenSeq,
              newTree(nnkPrefix, ident("@"), newTree(nnkBracket, child)),
            )
      fields.add(
        newTree(nnkExprColonExpr,
          newIdentNode("children"),
          childrenSeq
        )
      )
    
    fields.add(
      newTree(
        nnkExprColonExpr,
        ident("elementId"),
        elementIdNode
      )
    )
    
    # Construct the HTMLNode
    var resultNode = newTree(nnkObjConstr, newIdentNode("HTMLNode"))
    for field in fields:
      resultNode.add(field)
    result = resultNode
  proc createTextElement(strLit: NimNode): NimNode =
    # expectKind(strLit, {nnkStrLit, nnkInfix, nnkIdent})
    result = newTree(nnkObjConstr,
      newIdentNode("HTMLNode"),
      newTree(nnkExprColonExpr,
        newIdentNode("kind"),
        newIdentNode("htmlnkText")
      ),
      newTree(nnkExprColonExpr,
        newIdentNode("text"),
        strLit
      )
    )
  proc createBodyElement(node: NimNode): NimNode =
    let componentInstanceId = createComponentInstanceId()
    result = newCall(ident("toBody"), node, componentInstanceId)  
   
  proc isToBody(node: NimNode): bool =
    return node.kind == nnkCall and node[0].strVal == "toBody"
  proc process(node: NimNode, isTopLevel: bool = false, wasComponent: bool = false): Result = 
    case node.kind
    of nnkStrLit:
      return Result(node: createTextElement(node))

    of nnkIdent:
      # if tag name- use that,
      # otherwise- is a component
      let tagName = toElementName(node.strVal)
      if not htmlElements.hasKey(tagName):
        # var componentCall = nnkCall.newTree(
        #   ident(node.strVal),
        # )
        return Result(node: createBodyElement(node)
        )
      else:
        # echo ":: createElement #1  IDENT"
        return Result(
          node: createElement(tagName, initTable[string, NimNode](), @[], @[], isTopLevel)
        )
    
    of nnkAccQuoted:
      # is a component
      return Result(node: createBodyElement(node))
    
    of nnkCall, nnkCommand:
      if node.len < 2:
        error "expected at least 2 arguments, got " & $node.len, node
      
      let callNode  = node[0]
      let callValue = node[1]


      var callNodeName: string

      var isQuoted = false
      if callNode.kind == nnkIdent:
        callNodeName = callNode.strVal
      elif callNode.kind == nnkAccQuoted:
        expectKind(callNode[0], nnkIdent)
        callNodeName = callNode[0].strVal
        isQuoted = true
      else:
        error "unexpected call node: " & $callNode.kind, callNode

      var elementName: string = callNodeName.toElementName()
      var isElement = false
      if not isQuoted:
        if elementName in htmlElements:
          isElement = true
        else:
          isElement = false
      
      if wasComponent:
        isElement = false  # TODO: THIS COULD BREAK STUFF I HAVE NOT TESTED IT

      if callNodeName == "target":
        if not wasComponent or isQuoted:
          # echo "IS ELEMENT OR QUOTED"
          if node.len != 2:
            error "expected only 2 arguments, got " & $node.len, node
          if callValue.kind notin {nnkIdent, nnkSym}:
            error "expected a target name (ident or sym), got " & $callValue.kind, callValue

          var nodeResult = Result()

          nodeResult.attributeName = "id"
          nodeResult.attributeValue = nnkPrefix.newTree(
            ident("$"),
            callValue
          )
          nodeResult.isQuotedAttribute = isQuoted
          return nodeResult

      # Handle style - BUT ONLY if we're dealing with CSS styling, not component parameters
      if callNodeName == "style":
        # Debug output to understand the context
        # echo "Processing style: isElement=", isElement, ", wasComponent=", wasComponent, ", isTopLevel=", isTopLevel, ", elementName=", elementName
        
        # Only treat as CSS style if:
        # 1. We're dealing with an HTML element (isElement = true), OR
        # 2. We're at top level (for global styles)
        # 3. We're NOT processing component parameters (wasComponent = false AND not isElement)
        
        let shouldTreatAsCSS = not wasComponent or isTopLevel
        # echo "shouldTreatAsCSS=", shouldTreatAsCSS
        
        if shouldTreatAsCSS:
          if node.len != 2:
            error "expected only 2 arguments, got " & $node.len, node
          
          # Handle style for HTML elements (create CSS and style elements)
          if callValue.kind in {nnkIdent, nnkSym}:
            var nodeResult = Result()
            nodeResult.styleResult = some(StyleResult(
              kind: srkRUNTIME,
              isQuoted: isQuoted,
              style: callValue
            ))
            return nodeResult
              
          # Handle compile-time styles
          let (properties, rules) = parseWrittenDocument(callValue).split()
          var nodeResult = Result()
          nodeResult.styleResult = some(StyleResult(
            kind: srkCOMPILE_TIME,
            isQuoted: isQuoted,
            properties: properties,
            rules: rules
          ))
          return nodeResult

        


      var body:    NimNode = newEmptyNode()
      var textArg: NimNode = newEmptyNode()
      if callValue.kind == nnkStmtList:
        if node.len != 2:
          error "expected only 2 arguments, got " & $node.len & "\n\n" & node.treeRepr, node

        body      = callValue
      # TODO: here
      # elif callValue.kind in {nnkStrLit, nnkIdent, nnkIntLit, nnkFloatLit}:
      else:
        if node.len == 3:
          if node[2].kind != nnkStmtList:
            error "expected a stmt list, got " & $node[2].kind, node[2]

          body    = node[2]
          textArg = callValue
        elif node.len == 2:
          textArg = callValue
        else:
          error "expected 2 or 3 arguments, got " & $node.len, node
      # else:
        # error "unexpected call value: " & $callValue.kind, callValue

      # echo "------------------"
      if body.kind != nnkEmpty:
        var children: seq[NimNode] = @[]
        if textArg.kind != nnkEmpty:
          children.add createTextElement(textArg)

        var attributes: Table[string, NimNode] = initTable[string, NimNode]()
        var styles: seq[StyleResult] = @[]
        var passthroughAttributes: seq[NimNode] = @[]
        # var passthroughEvents: seq[NimNode] = @[]

        # var wasComponentSeq: NimNode = nnkPrefix.newTree(ident("@"), newTree(nnkBracket))
        var wasComponentSeq: NimNode = newEmptyNode()

        # echo "HERE: " & callNodeName & " is " & $wasComponent
        for child in body:
          let childWasComponent = if wasComponent and not isElement:
            false  # This is a component parameter block containing HTML
          else:
            not isElement
          let childResult = process(child, false, childWasComponent)
          if childResult.styleResult.isSome:
            let styleResult = childResult.styleResult.get()
            # echo "Adding to styles!"
            styles.add(styleResult)

          # echo "Got child result: " & childResult.repr
          # if is element, expect all: elements, components, or attributes
          # if not is element, expect component inputs and passthrough attributes
          if isElement:
            if childResult.node != nil:
              # echo child.repr
              # echo "Found child node: " & childResult.node.repr & " : " & child.repr
              children.add(childResult.node)
            
            # if childResult.attributeName == "style":
            #   if childResult.isQuotedAttribute:
            #     error "Passthrough attributes are not allowed for elements", childResult.attributeValue

            #   var existingValue: NimNode = newEmptyNode()
            #   if attributes.hasKey(childResult.attributeName):
            #     existingValue = attributes[childResult.attributeName]

            #   var newValue = childResult.attributeValue
            #   if newValue.kind == nnkIdent:
            #     newValue = nnkCall.newTree(
            #       ident("$"),
            #       newValue,
            #     )
            #   # echo "ADDINGGGGG "
            #   # echo "EXISTING: " & existingValue.repr
            #   # echo "NEW: " & newValue.repr
            #   if existingValue.kind != nnkEmpty:
            #     existingValue = nnkInfix.newTree(
            #       ident("&"),
            #       existingValue,
            #       newStrLitNode("; "),
            #     )
            #     existingValue = nnkInfix.newTree(
            #       ident("&"),
            #       existingValue,
            #       newValue,
            #     )
            #   else:
            #     existingValue = newValue
            #   attributes[childResult.attributeName] = existingValue

            if childResult.attributeName != "":
              if childResult.isQuotedAttribute:
                error "Passthrough attributes are not allowed for elements", childResult.attributeValue
              
              if childResult.attributeName == "class":
                # append to existing class
                var existingValue: NimNode = newEmptyNode()
                if attributes.hasKey(childResult.attributeName):
                  existingValue = attributes[childResult.attributeName]
                
                if existingValue.kind != nnkEmpty:
                  attributes[childResult.attributeName] = nnkInfix.newTree(
                    ident("&"),
                    nnkInfix.newTree(
                      ident("&"),
                      existingValue,
                      newStrLitNode(" ")
                    ),
                    childResult.attributeValue
                  )
                else:
                  attributes[childResult.attributeName] = childResult.attributeValue
                
                

              else:

                if attributes.hasKey(childResult.attributeName):
                  error "Duplicate attribute: " & childResult.attributeName, childResult.attributeValue
                
                # echo "Found attribute: " & childResult.attributeName
                if childResult.attributeName.toLower() in JS_EVENTS:
                  let eventName = childResult.attributeName.toLower()
                  # echo "Got event: " & eventName
                  # echo "Value: " & childResult.attributeValue.repr
                  # echo "Found event attribute: " & eventName
                  # echo "VALUE: " & childResult.attributeValue.repr


                  attributes[eventName] = newStrLitNode("window.dispatchEvent(" & childResult.attributeValue.repr & ")")
                  # attributes[eventName] = newStrLitNode("(function(e) {  window['" & eventName & "'] = e; window.dispatchEvent(new Event('" & eventName & "'));  })(event)")
                
                  # make attributes[eventName] a new strlit node: window.dispatchEvent ( ident str val )
                  # attributes[eventName] = newStrLitNode("window.dispatchEvent(new Event('" & 
                
                else:
                  attributes[childResult.attributeName] = childResult.attributeValue

          else:            
            if childResult.node != nil:
              # echo childResult.node.treeRepr
              if wasComponent:
                # we are a components inputs parsed node
                # attributes[callNodeName] = childResult.node

                

                # echo "WAS COMPONENT SEQ: " & childResult.node.repr
                # echo "CURRENT SEQ: "
                # echo wasComponentSeq.repr
                if childResult.node.isToBody():
                  if wasComponentSeq.kind == nnkEmpty:
                    wasComponentSeq = childResult.node
                  else:
                    wasComponentSeq = newTree(
                      nnkInfix,
                      ident("&"),
                      wasComponentSeq,
                      childResult.node
                    )
                elif wasComponentSeq.kind == nnkEmpty:
                  wasComponentSeq = newTree(nnkPrefix, ident("@"), newTree(nnkBracket, childResult.node))
                elif wasComponentSeq.kind == nnkPrefix and wasComponentSeq[0].strVal == "@":
                  wasComponentSeq[1].add(childResult.node)
                elif wasComponentSeq.kind == nnkInfix:
                  wasComponentSeq = newTree(
                    nnkInfix,
                    ident("&"),
                    wasComponentSeq,
                    newTree(nnkPrefix, ident("@"), newTree(nnkBracket, childResult.node)),
                  )
                elif wasComponentSeq.isToBody():
                  wasComponentSeq = newTree(
                    nnkInfix,
                    ident("&"),
                    wasComponentSeq,
                    newTree(nnkPrefix, ident("@"), newTree(nnkBracket, childResult.node)),
                  )
                else:
                  error "Unexpected node type: " & $wasComponentSeq.kind, wasComponentSeq


                # wasComponentSeq[1].add(childResult.node)
              else:
                # error "Unexpected node for component, expect inputs only: " & $childResult.node.kind & "\n" & childResult.node.treeRepr, childResult.node
                error "Unexpected node for component, expects inputs only, got: " & $childResult.node.kind & "\n\nThis was likely parsed as a element." & "\n" & childResult.repr, childResult.node
            # if childResult.class != nil and childResult.class.kind != nnkEmpty:
            #   # echo "Found class: " & childResult.class.repr
            #   if attributes.hasKey("class"):
            #     attributes["class"] = nnkInfix.newTree(
            #       ident("&"),
            #       attributes["class"],
            #       childResult.class
            #     )
            #   else:
            #     attributes["class"] = childResult.class
            
            if childResult.attributeName != "":
              # if isQuoted: passthrough attribute
              #   otherwise: is a component input
              
              # echo "Found component input: " & childResult.attributeName
              if childResult.isQuotedAttribute:
                # echo "DETECTED QUOTED ATTRIBUTE: ", childResult.attributeName, " = ", childResult.attributeValue.repr
                # echo "..."
                # TODO: here
                if isElement:
                  error "Passthrough attributes are only allowed for components", childResult.attributeValue
                # passthroughAttributes[childResult.attributeName] = childResult.attributeValue
                # passthroughAttributes.add nnkTupleConstr.newTree(
                #   newStrLitNode(childResult.attributeName),
                #   childResult.attributeValue
                # )

                # echo "PASS THROUGH"
                # echo childResult.repr

                if childResult.attributeName.toLower() in JS_EVENTS:
                  let eventName = childResult.attributeName.toLower()
                  # Use IDENTICAL processing to regular events
                  passthroughAttributes.add nnkTupleConstr.newTree(
                    newStrLitNode(childResult.attributeName),
                    newStrLitNode("window.dispatchEvent(" & childResult.attributeValue.repr & ")")
                  )
                else:
                  passthroughAttributes.add nnkTupleConstr.newTree(
                    newStrLitNode(childResult.attributeName),
                    childResult.attributeValue
                  )
              else:
                attributes[childResult.attributeName] = childResult.attributeValue
                # echo childResult.attributeValue.repr
        
        # echo "GOT HERE: " & callNodeName & " : " & $isElement'
# Fix for the component processing logic
# Replace the section starting with "# echo "GOT HERE: " & callNodeName & " : " & $isElement"

        # echo "GOT HERE: " & callNodeName & " : " & $isElement
        
        # Check if this is an HTML element first, regardless of component context
        if isElement:
          # echo ":: createElement #2  CALL"
          # echo styles.len
          return Result(
            node: createElement(elementName, attributes, styles, children, isTopLevel)
          )
        # If not an HTML element and we're in a component context
        if wasComponent:
          log "wasComponent, giving back: " & callNodeName
          
          for attribName, attribValue in attributes:
            log "But got " & attribName & ": " & attribValue.repr
          
          # ALWAYS create a component call when there are passthrough attributes
          # even if wasComponentSeq is not empty
          if passthroughAttributes.len > 0:
            # echo "CREATING COMPONENT CALL FOR wasComponent WITH PASSTHROUGH ATTRIBUTES: ", passthroughAttributes.len
            
            var componentCall = nnkCall.newTree(
              newIdentNode(callNodeName),
            )

            componentCall.add(
              nnkExprEqExpr.newTree(
                ident("key"),
                createComponentInstanceId()
              )
            )
            
            # Add regular attributes
            for inputName, inputValue in attributes:
              componentCall.add(
                newTree(nnkExprEqExpr,
                  ident(inputName),
                  inputValue
                )
              )
            
            # Add the main content if it exists
            if wasComponentSeq.kind != nnkEmpty:
              componentCall.add(
                newTree(nnkExprEqExpr,
                  ident(callNodeName),  # e.g., "children"
                  wasComponentSeq
                )
              )
            
            componentCall = nnkCall.newTree(
              ident("addPassthroughAttributes"),
              componentCall,
              nnkCall.newTree(
                nnkDotExpr.newTree(
                  nnkPrefix.newTree(
                    ident("@"),
                    nnkBracket.newTree(
                      passthroughAttributes
                    )
                  ),
                  ident("toTableRef")
                )
              )
            )
            
            return Result(
              node: nnkCall.newTree(
                ident("toBody"),
                componentCall,
                newStrLitNode("")
              )
            )
          
          # Original logic for when there are no passthrough attributes
          if wasComponentSeq.kind == nnkEmpty:
            # Only create component calls for non-HTML elements
            var componentCall = nnkCall.newTree(
              newIdentNode(callNodeName),
            )
            componentCall.add(
              nnkExprEqExpr.newTree(
                ident("key"),
                createComponentInstanceId()
              )
            )
            for inputName, inputValue in attributes:
              componentCall.add(
                newTree(nnkExprEqExpr,
                  ident(inputName),
                  inputValue
                )
              )
            
            return Result(
              node: nnkCall.newTree(
                ident("toBody"),
                componentCall,
                newStrLitNode("")
              )
            )
          
          return Result(
            attributeName: callNodeName,
            attributeValue: wasComponentSeq,
          )
        
        # If not an element and not in component context, treat as standalone component
        else:
          # TODO: do type checking, import

          var componentCall = nnkCall.newTree(
            newIdentNode(callNodeName),
          )
          componentCall.add(
            nnkExprEqExpr.newTree(
              ident("key"),
              createComponentInstanceId()
            )
          )

          for inputName, inputValue in attributes:
            componentCall.add(
              newTree(nnkExprEqExpr,
                ident(inputName),
                inputValue
              )
            )

          if passthroughAttributes.len > 0:
            # echo "#1 WRAPPING COMPONENT WITH PASSTHROUGH ATTRIBUTES: ", passthroughAttributes.len
            componentCall = nnkCall.newTree(
              ident("addPassthroughAttributes"),
              componentCall,
              nnkCall.newTree(
                nnkDotExpr.newTree(
                  nnkPrefix.newTree(
                    ident("@"),
                    nnkBracket.newTree(
                      passthroughAttributes
                    )
                  ),
                  ident("toTableRef")
                )
              )
            )



          return Result(
            node: createBodyElement(componentCall)
          )

      if textArg.kind != nnkEmpty:
        # is attribute of callNodeName
        # if isQuoted: passthrough attribute
        
        # if element name- this is the inside text
        if isElement:
          # echo ":: createElement #4  TEXT"
          return Result(
            node: createElement(elementName, initTable[string, NimNode](), @[], @[
              createTextElement(textArg)
            ], isTopLevel)
          )
        else:
          let attributeName  = callNodeName
          let attributeValue = callValue

          # if isQuoted:
            # echo "..."
            # error "not implemented"
          return Result(
            attributeName: attributeName,
            attributeValue: attributeValue,
            isQuotedAttribute: isQuoted,
          )
        
    else:
      error "Unsupported node: " & $node.kind, node
  

  if body.kind != nnkStmtList:
    error "web macro expected a stmt list, got " & $body.kind, body
  
  # var topLevelResultingNodes: seq[NimNode] = @[]
  # for child in body.children:
  #   let childResult = process(child, true)
  #   if childResult.attributeName != "":
  #     error "Attribute not allowed at root level: " & childResult.attributeName, childResult.attributeValue
    

  #   topLevelResultingNodes.add(childResult.node)
  
  # var resultBody = nnkPrefix.newTree(
  #   ident("@"),
  #   nnkBracket.newTree(
  #     topLevelResultingNodes
  #   )
  # )

  var resultBody: NimNode = newEmptyNode()
  for child in body.children:
    let childResult = process(child, true)
    if childResult.attributeName != "":
      error "Attribute not allowed at root level: " & childResult.attributeName, childResult.attributeValue
    
    if childResult.node.isToBody():
      if resultBody.kind == nnkEmpty:
        resultBody = childResult.node
      else:
        resultBody = newTree(
          nnkInfix,
          ident("&"),
          resultBody,
          childResult.node
        )
    else:
      if resultBody.kind == nnkEmpty:
        var childNode: NimNode = childResult.node
        if childNode.kind == nnkNilLit and childResult.styleResult.isSome:
          let styles = @[childResult.styleResult.get()]
          childNode = createElement("nil", initTable[string, NimNode](), styles, @[], true, true)

        resultBody = nnkPrefix.newTree(
          ident("@"),
          newTree(nnkBracket, childNode)
        )
      elif resultBody.kind == nnkPrefix and resultBody[0].strVal == "@":
        resultBody[1].add(childResult.node)
      elif resultBody.kind == nnkInfix:
        resultBody = newTree(
          nnkInfix,
          ident("&"),
          resultBody,
          nnkPrefix.newTree(
            ident("@"),
            newTree(nnkBracket, childResult.node)
          )
        )
      elif resultBody.isToBody():
        resultBody = newTree(
          nnkInfix,
          ident("&"),
          resultBody,
          nnkPrefix.newTree(
            ident("@"),
            newTree(nnkBracket, childResult.node)
          )
        )
      else:
        error "Unexpected node type: " & $resultBody.kind, resultBody


  # if styles.len > 0:
  #   # Convert styles to a NimNode
  #   var (styleContent, _) = styles.toNimNode()
    
  #   if styleContent.kind != nnkEmpty:
  #     # Create a style element with the styles
  #     let styleNode = createElement("style", initTable[string, NimNode](), @[
  #       createTextElement(styleContent)
  #     ], false)
      
  #     # Add the style element to the beginning of resultBody
  #     if resultBody.kind == nnkEmpty:
  #       resultBody = nnkPrefix.newTree(
  #         ident("@"),
  #         newTree(nnkBracket, styleNode)
  #       )
  #     elif resultBody.kind == nnkPrefix and resultBody[0].strVal == "@":
  #       # Insert at the beginning of the array
  #       let oldBracket = resultBody[1]
  #       let newBracket = nnkBracket.newTree(styleNode)
  #       for child in oldBracket:
  #         newBracket.add(child)
  #       resultBody[1] = newBracket
  #     elif resultBody.kind == nnkInfix:
  #       # Add to the beginning
  #       resultBody = newTree(
  #         nnkInfix,
  #         ident("&"),
  #         nnkPrefix.newTree(
  #           ident("@"),
  #           newTree(nnkBracket, styleNode)
  #         ),
  #         resultBody
  #       )
  #     elif resultBody.isToBody():
  #       # Ensure it's within toBody
  #       resultBody = newTree(
  #         nnkInfix,
  #         ident("&"),
  #         nnkPrefix.newTree(
  #           ident("@"),
  #           newTree(nnkBracket, styleNode)
  #         ),
  #         resultBody
  #       )

  let wrappedBody = nnkCall.newTree(
    ident("fixVoidElementsWithStyles"),
    resultBody,
    newStrLitNode(thingUuid)
  )
  return (wrappedBody, eventHandlers)


# TODO:
#  1.  Add fixVoidElementsWithStyles
#  2.  Re-integrate styles


macro web*(body: untyped): untyped =
  let (htmlResult, eventHandlers) = handleWeb(body, "html", "html2")

  if eventHandlers.len > 0:
    warning "web macro: Event handlers are not supported in this context."
    log "Event handlers:"
    log eventHandlers.repr
  
  # echo "\nFINAL RESULT:"
  # echo htmlResult.repr

  result = htmlResult

# Add this debug output to the addPassthroughAttributes macro to see what's happening:

macro addPassthroughAttributes*(body: untyped, passthroughAttributes: untyped): untyped =
  # Add debug output
  # echo "addPassthroughAttributes called with:"
  # echo "passthroughAttributes: ", passthroughAttributes.repr
  
  var eventHandlerStmts = newStmtList()
  
  let resultNode = ident("resultNode")

  # Process the attributes at compile time to extract event info
  if passthroughAttributes.kind == nnkCall and passthroughAttributes[0].kind == nnkDotExpr:
    let arrayPart = passthroughAttributes[0][0]  # @[...]
    if arrayPart.kind == nnkPrefix and arrayPart[1].kind == nnkBracket:
      # echo "Found bracket with ", arrayPart[1].len, " elements"
      for i, tupleNode in arrayPart[1]:
        # echo "Element ", i, ": ", tupleNode.repr
        if tupleNode.kind == nnkTupleConstr and tupleNode.len >= 2:
          let attrName = tupleNode[0]
          let attrValue = tupleNode[1] 
          # echo "  Attribute: ", attrName.repr, " = ", attrValue.repr
          
          # Check for event dispatch pattern
          if (attrValue.kind == nnkStrLit and 
              attrValue.strVal.startsWith("window.dispatchEvent(") and
              not attrValue.strVal.startsWith("window.dispatchEvent(\"")):
            
            let handlerName = attrValue.strVal.split("(")[1].split(")")[0]
            let handlerIdent = ident(handlerName)
            
            # Generate event listener setup - IDENTICAL to createElement
            eventHandlerStmts.add quote do:
              let eventName = `attrName` & "_" & `resultNode`.elementId
              
              when defined(js):
                window.addEventListener(eventName, proc(event: Event) =
                  let customEvent = cast[JsObject](event)
                  let detail = customEvent["detail"]
                  let originalEventObject = detail["originalEvent"]
                  let originalEvent = cast[Event](originalEventObject)
                  `handlerIdent`(originalEvent)  # Handler ident generated at compile time
                )
              `resultNode`.attributes[`attrName`] = "(function(e) {  window.dispatchEvent(new CustomEvent('" & eventName & "', { detail: { originalEvent: e } } ))  })(event)"

  result = quote do:
    block:
      let body = `body`
      var resultBody: seq[HTMLNode] = @[]

      for node in body:
        var `resultNode` = node
        
        # Debug output
        # echo "Processing node with elementId: ", `resultNode`.elementId
        # echo "Existing attributes: ", `resultNode`.attributes
        
        # Apply non-event attributes
        for attrName, attrValue in `passthroughAttributes`:
          let value = $attrValue
          # echo "Applying attribute: ", attrName, " = ", value
          if not (value.startsWith("window.dispatchEvent(") and not value.startsWith("window.dispatchEvent(\"")):
            if attrName == "style" and `resultNode`.attributes.hasKey("style"):
              `resultNode`.attributes["style"] = `resultNode`.attributes["style"] & "; " & value
            else:
              `resultNode`.attributes[attrName] = value
        
        # Debug output after applying attributes
        # echo "Final attributes: ", `resultNode`.attributes
        
        # Set up event listeners and attributes - processed at compile time
        `eventHandlerStmts`
        
        resultBody.add(`resultNode`)

      resultBody

# Add the computeDirectStyles function that will be called by the generated code
proc computeDirectStyles*(styles: auto): string =
  ## Extract direct styles from a Styles object and format them as inline CSS
  when styles is Styles:
    return $styles.direct
  else:
    return ""

when isMainModule:
  let key = "test"

  proc aComponent(key: string = ""): HTML =
    return web:
      p "A Component!"

  var styles = newStyles()
  styles.color = "red"

  let htmls = web:
    box:
      name "stuff!"

      aComponent
  
  echo $htmls


  # TODO: Try :root and pseudo-root-level styles

  # var styles1 = newStyles()
  # styles1.color = "red"

  # let dynamicColor = "magenta"
  # styles1.backgroundColor = `dynamicColor`


  # var styles2 = newStyles()
  # styles2.color = "blue"
  # styles2.add:
  #   [hover]:
  #     opacity: 0.8
  #   [hover, active]:
  #     backgroundColor: `dynamicColor`

  #   body:
  #     backgroundColor: "yellow"

  #   [root]:
  #     backgroundColor: "black"

  # proc aComponent(id: string, children: HTML): HTML =
  #   return web:
  #     p "This is a component!"

  # let htmls = web:
  #   aComponent:
  #     `name` "name!!"
  #     id "testing!"
  #     children:
  #       p "test"
  #   box:
  #     # p "Runtime test":
  #     #   style styles1
  #     # p "Compile-time test":
  #     #   style:
  #     #     color: orange
  #     #     backgroundColor: `dynamicColor`

  #     p "Runtime test with styles":
  #       style styles2
      # p "Compile-time test with styles":
      #   style:
      #     [hover]:
      #       opacity: 0.2
      #     [hover, active]:
      #       backgroundColor: `dynamicColor`
      #     body:
      #       backgroundColor: "green"

  # let htmls = web:
  #   # p "Test"
  #   style:
  #     body:
  #       color: red
  #   style:
  #     [root]:
  #       backgroundColor: black

  # echo htmls