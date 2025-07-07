import macros, tables, options, strutils

import web/util
export util

import pkg/css
import pkg/html

export css
export html

const DO_VALIDATE = false
const DO_LOG = true


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


# TODO: this should not be a seperate loopo
proc fixVoidElementsWithStyles*(nodes: seq[HTMLNode]): seq[HTMLNode] =
  ## Post-processes HTML nodes to move <style> elements out of void elements
  ## and validates that void elements don't have other invalid content
  
  result = @[]
  
  for node in nodes:
    case node.kind:
    of htmlnkElement:
      # Check if this is a void element with children
      if node.tag in VOID_ELEMENTS and node.children.len > 0:
        var extractedStyles: seq[HTMLNode] = @[]
        
        # Process children of void element
        for child in node.children:
          if child.kind == htmlnkElement and child.tag == "style":
            # Extract style element
            extractedStyles.add(child)
          else:
            # Error: void element has non-style content
            raise newException(ValueError, "Void element '" & node.tag & "' cannot contain content other than styles")
        
        # Add extracted styles first
        result.add(extractedStyles)
        
        # Add the void element without children
        var cleanVoidElement = node
        cleanVoidElement.children = @[]
        result.add(cleanVoidElement)
      
      else:
        # Not a void element or no children - process children recursively
        var processedNode = node
        if node.children.len > 0:
          processedNode.children = fixVoidElementsWithStyles(node.children)
        result.add(processedNode)
    
    of htmlnkText:
      # Text nodes are fine as-is
      result.add(node)

type WebResponse = tuple[body: NimNode, eventHandlers: NimNode]
proc handleWeb*(inputBody: NimNode, thingUuid: string, thisUuid: string, styles: seq[WrittenDocumentNode] = @[]): WebResponse =
  var topElementId = thingUuid & ":" & thisUuid

  # echo "HANDLING WEB WITH UUID"
  # echo thingUuid
  # echo thisUuid

  # let (doc, body) = computeStyles("element", inputBody)
  var body = inputBody


  type Result = object
    node: NimNode
    
    attributeName: string = ""
    attributeValue: NimNode
    isQuotedAttribute: bool = false

    parentStyles: NimNode

  var elementCount = 0
  proc uniqueElementId(): int =
    elementCount += 1
    return elementCount


  let eventHandlers = newStmtList()

  proc createElement(tagName: string, attributes: Table[string, NimNode], children: seq[NimNode], isTopLevel: bool): NimNode =
    var fields = @[
      newTree(nnkExprColonExpr,
        newIdentNode("kind"),
        newIdentNode("htmlnkElement")
      ),
      newTree(nnkExprColonExpr,
        newIdentNode("tag"),
        newStrLitNode(tagName)
      )
    ]
    var modAttributes = attributes
    # add "element-id" attribute
    let index = uniqueElementId()
    var elementId = topElementId
    if not isTopLevel:
      elementId &= "-" & $index
    
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
        newIdentNode("toTable")
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
        newStrLitNode(elementId)
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
    result = newCall(ident("toBody"), node)  
   
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
        return Result(node: createBodyElement(node)
        )
      else:
        return Result(
          node: createElement(tagName, initTable[string, NimNode](), @[], isTopLevel)
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
      
      if callNodeName == "style":
        if node.len != 2:
          error "expected only 2 arguments, got " & $node.len, node
        
        if not wasComponent:
          # Handle style for HTML elements (create CSS and style elements)
          if callValue.kind in {nnkIdent, nnkSym}:
            # echo "IDENT DETECTED"
            
            # Generate both the style element and the class attribute
            var nodeResult = Result()
            
            # Create the <style> element with the computed CSS
            nodeResult.node = createElement("style", initTable[string, NimNode](), @[
              createTextElement(
                nnkCall.newTree(
                  ident("computeClassesStr"),
                  newStrLitNode("obj-" & thingUuid),
                  callValue
                )
              )
            ], isTopLevel)
            
            # Set the class attribute
            nodeResult.attributeName = "class"
            nodeResult.attributeValue = nnkCall.newTree(
              ident("computeClasses"),
              newStrLitNode("obj-" & thingUuid),
              callValue
            )
            
            nodeResult.isQuotedAttribute = isQuoted
            return nodeResult
          
          if callValue.kind != nnkStmtList:
            error "expected a stmt list, got " & $callValue.kind, callValue

          let computedStylesDoc = computeStyles("non-" & thingUuid, callValue)
          # echo "COMPUTING UUID: " & thingUuid

          # echo "GOT COMPUTED STYLES DOC:"
          # echo computedStylesDoc.treeRepr        
          # Separate root-level properties from CSS selectors/rules
          let (rootLevelProperties, cssSelectorsAndRules) = separateStyleContent(computedStylesDoc)
          
          # echo "ROOT LEVEL PROPERTIES: " & $rootLevelProperties.len
          # echo "CSS SELECTORS/RULES: " & $cssSelectorsAndRules.len

          var nodeResult = Result()
          
          # Create <style> element if we have ANY styles (root properties OR selectors/rules)
          if rootLevelProperties.len > 0 or cssSelectorsAndRules.len > 0:
            # Use computeClassesStr on the original computedStylesDoc which handles both cases
            let computedStr = computeClassesStr("non-" & thingUuid, computedStylesDoc)
            # echo "Generated CSS: " & $computedStr
            
            nodeResult.node = createElement("style", initTable[string, NimNode](), @[
              createTextElement(newStrLitNode($computedStr))
            ], isTopLevel)
          
          # Set class attribute if there are root-level properties
          if rootLevelProperties.len > 0:
            nodeResult.attributeName = "class"
            nodeResult.attributeValue = newStrLitNode(computeClasses("non-" & thingUuid, rootLevelProperties))
          
          nodeResult.isQuotedAttribute = isQuoted
          return nodeResult
        else:
          # Handle style for components - create a Styles object from the style block
          if callValue.kind in {nnkIdent, nnkSym}:
            # Pass through the identifier as-is (e.g., style styles2)
            return Result(
              attributeName: "style",
              attributeValue: callValue,
              isQuotedAttribute: isQuoted
            )
          
          if callValue.kind != nnkStmtList:
            error "expected a stmt list for component style, got " & $callValue.kind, callValue
          
          # For component style blocks, create a block that builds a Styles object
          var stylesBlock = nnkBlockStmt.newTree(
            newEmptyNode(),
            nnkStmtList.newTree()
          )
          
          let blockBody = stylesBlock[1]
          
          # Create the styles variable
          blockBody.add nnkVarSection.newTree(
            nnkIdentDefs.newTree(
              ident("result"),
              ident("Styles"),
              nnkCall.newTree(ident("newStyles"))
            )
          )
          
          # Transform each style property in the block
          for styleChild in callValue:
            case styleChild.kind:
            of nnkCall:
              if styleChild.len == 2:
                let propName = styleChild[0]
                let propValue = styleChild[1]
                
                # Create assignment: result.propName = propValue
                blockBody.add nnkAsgn.newTree(
                  nnkDotExpr.newTree(ident("result"), propName),
                  propValue
                )
            of nnkExprColonExpr:
              let propName = styleChild[0]
              let propValue = styleChild[1]
              
              # Create assignment: result.propName = propValue
              blockBody.add nnkAsgn.newTree(
                nnkDotExpr.newTree(ident("result"), propName),
                propValue
              )
            else:
              # For other node types, try to process them as well
              blockBody.add styleChild
          
          # Return the result
          blockBody.add ident("result")
          
          return Result(
            attributeName: "style",
            attributeValue: stylesBlock,
            isQuotedAttribute: isQuoted
          )


      var body:    NimNode = newEmptyNode()
      var textArg: NimNode = newEmptyNode()
      if callValue.kind == nnkStmtList:
        if node.len != 2:
          error "expected only 2 arguments, got " & $node.len, node

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
        var passthroughAttributes: seq[NimNode] = @[]
        # var passthroughEvents: seq[NimNode] = @[]

        # var wasComponentSeq: NimNode = nnkPrefix.newTree(ident("@"), newTree(nnkBracket))
        var wasComponentSeq: NimNode = newEmptyNode()

        # echo "HERE: " & callNodeName & " is " & $wasComponent
        for child in body:
         
          # echo "PROCESSING"
          # echo child.treeRepr
          let childResult = process(child, false, not isElement)
          # echo "Got child result: " & childResult.repr
          # if is element, expect all: elements, components, or attributes
          # if not is element, expect component inputs and passthrough attributes
          if isElement:
            if childResult.node != nil:
              # echo child.repr
              # echo "Found child node: " & childResult.node.repr & " : " & child.repr
              children.add(childResult.node)
            
            if childResult.attributeName == "style":
              if childResult.isQuotedAttribute:
                error "Passthrough attributes are not allowed for elements", childResult.attributeValue

              var existingValue: NimNode = newEmptyNode()
              if attributes.hasKey(childResult.attributeName):
                existingValue = attributes[childResult.attributeName]

              var newValue = childResult.attributeValue
              if newValue.kind == nnkIdent:
                newValue = nnkCall.newTree(
                  ident("$"),
                  newValue,
                )
              # echo "ADDINGGGGG "
              # echo "EXISTING: " & existingValue.repr
              # echo "NEW: " & newValue.repr
              if existingValue.kind != nnkEmpty:
                existingValue = nnkInfix.newTree(
                  ident("&"),
                  existingValue,
                  newStrLitNode("; "),
                )
                existingValue = nnkInfix.newTree(
                  ident("&"),
                  existingValue,
                  newValue,
                )
              else:
                existingValue = newValue
              attributes[childResult.attributeName] = existingValue
            
            elif childResult.attributeName != "":
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
                error "Unexpected node for component, expect inputs only: " & $childResult.node.kind, childResult.node
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
          return Result(
            node: createElement(elementName, attributes, children, isTopLevel)
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
            
            # Wrap with passthrough attributes
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
                  ident("toTable")
                )
              )
            )
            
            return Result(
              node: nnkCall.newTree(
                ident("toBody"),
                componentCall
              )
            )
          
          # Original logic for when there are no passthrough attributes
          if wasComponentSeq.kind == nnkEmpty:
            # Only create component calls for non-HTML elements
            var componentCall = nnkCall.newTree(
              newIdentNode(callNodeName),
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
                componentCall
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
                  ident("toTable")
                )
              )
            )



          return Result(
            node: createBodyElement(componentCall)
          )

        if isElement:
          return Result(
            node: createElement(elementName, attributes, children, isTopLevel)
          )
        else:
          # TODO: do type checking, import
          var componentCall = nnkCall.newTree(
            newIdentNode(callNodeName),
          )

          for inputName, inputValue in attributes:
            componentCall.add(
              newTree(nnkExprEqExpr,
                ident(inputName),
                inputValue
              )
            )

          # echo "CALL: " & componentCall.repr

          if passthroughAttributes.len > 0:
            # echo "#2 WRAPPING COMPONENT WITH PASSTHROUGH ATTRIBUTES: ", passthroughAttributes.len
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
                  ident("toTable")
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
          return Result(
            node: createElement(elementName, initTable[string, NimNode](), @[
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
        resultBody = nnkPrefix.newTree(
          ident("@"),
          newTree(nnkBracket, childResult.node)
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
    resultBody
  )
  return (wrappedBody, eventHandlers)



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

when isMainModule:


  # # let htmlss = HTML(@[HTMLNode(
  # #   kind: htmlnkText,
  # #   text: "Hello World!"
  # # )])
  # proc row(children: HTML): HTML =
  #   return web:
  #     box:
  #       name "row"
  #       children

  # proc tile(num: Option[int] = none(int)): HTML =
  #   var tileText = "Tile " & $num
  #   return web:
  #     p:
  #       tileText
  #     # children
  
  # proc onclickhandler(): void =
  #   echo "Clicked!"
  #   # echo event
  

  # let content = web:
  #   p "Hello world":
  #     name "helloWorld"

  # let htmls = web:
  
    

  #   box:
  #     name "box"
  #     content


  #     # onclick onclickhandler
  #     # row:
  #     #   children:
  #     #     tile:
  #     #       num some(5)
  #     #     tile
  #     #     tile
  #     #     tile

  #   # component:
  #   #   children:
  #   #     h1 "Testing!"
  #   #     aNumber:
  #   #       children:
  #   #         h2 "Done!"

  #         # aNumber:
  #         #   children:
  #         #     h1 "Hello world"
  #           # number some(42)
  #       # number some(5)
  #       # `anAttribute` "hello world"
  #       # `style`:
  #         # color: orange
  #       # children:
  #       #   htmlss
  #       #   htmlss
  #       #   htmlss

  #     # p "Test"
  #       # anything:
  #         # h2 "An H2!"
  #         # h3 "An H333"






  import thing/thing_seed/src/thing_seed/dom

  # var styles = newStyles()
  # styles.color = "red"
  proc aComponent(): HTML =
    return web:
      box:
        name "aComponent"
        p "Hello world!"

  proc mouseEntered(event: Event): void =
    echo "Mouse entered on aComponent with event: " & event.repr

  let htmls = web:

    box:
      onmouseenter mouseEntered

      aComponent:
        `onmouseenter` mouseEntered
        # `id` "someId!"
        # `onmouseenter` mouseEntered

    # h1 "Hello world"
    # aComponent:
    #   children:
    #     p:
    #       "Hello world!"
        # p "This is a paragraph inside the component"
        # p "This is


    # globalStyles
      # aComponent:
      #   text "Hello from aComponent"
      #   `id` "this gets passed through fine, this works!"
        # `style` styles2
        # `style` styles2
        # `test` "Test attribute"
        # `style`:
          # color: "blue"

        # @keyframes test:
        #   "to":
        #     transform: scale(2)
      # style styles

  log "Final HTML:"
  log htmls.treeRepr
  log $htmls







