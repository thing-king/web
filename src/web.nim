import macros, tables, options, strutils

import web/util

import pkg/css
import pkg/html



type WebResponse = tuple[body: NimNode, eventHandlers: NimNode]
proc handleWeb*(body: NimNode, topElementId: string): WebResponse =
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

  proc process(node: NimNode, isTopLevel: bool = false, wasComponent: bool = false): Result =
    proc createElement(tagName: string, attributes: Table[string, NimNode], children: seq[NimNode]): NimNode =
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
      modAttributes["element-id"] = newStrLitNode(elementId)
        
    
      var tuples = newTree(nnkBracket)
      for key, rawValue in modAttributes:
        var value = rawValue
        if value.kind == nnkStrLit and value.strVal.startsWith("window.dispatchEvent(") and not value.strVal.startsWith("window.dispatchEvent(\""): 
          let eventName = key & "_" & elementId
          let handlerIdent = ident(value.strVal.split("(")[1].split(")")[0])
          value = newStrLitNode("window.dispatchEvent(new Event('" & eventName & "'))")
          let eventNameStrLit = newStrLitNode(eventName)
          eventHandlers.add quote do:
            window.addEventListener(`eventNameStrLit`, `handlerIdent`)
        
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
      expectKind(strLit, {nnkStrLit, nnkInfix})
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
          node: createElement(tagName, initTable[string, NimNode](), @[])
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
        if callValue.kind != nnkStmtList:
          error "expected a stmt list, got " & $callValue.kind, callValue

        var styleContent: NimNode = newEmptyNode()
        var inlineStyles: seq[NimNode] = @[]

        var parentStyles: NimNode = newEmptyNode()
        let items: seq[WrittenDocumentNode] = parseWrittenDocument(callValue)
        for item in items:
          if item.kind == cssikRULE:
            let content = newStrLitNode(item.rule.selector & " { ")
            styleContent = styleContent.concat(content)

            for property in item.rule.properties:
              if property.body.kind == pkPURE:
                styleContent = styleContent.concat(newStrLitNode(property.name & ": " & property.body.value & "; "))
              else:
                styleContent = styleContent.concat(newStrLitNode(property.name & ": "))
                styleContent = styleContent.concat(
                  nnkCall.newTree(
                  ident("validatePropertyValue"),
                  newStrLitNode(property.name),
                  property.body.node
                  )
                )
                styleContent = styleContent.concat(newStrLitNode("; "))
            styleContent = styleContent.concat(newStrLitNode("} "))
          elif item.kind == cssikINLINE:
            styleContent = styleContent.concat(newStrLitNode(item.content))
            styleContent = styleContent.concat(newStrLitNode("; "))
          else:
            if item.property.body.kind == pkPURE:
              inlineStyles.add(newStrLitNode(item.property.name & ": " & item.property.body.value))
            else:
              inlineStyles.add(
                nnkInfix.newTree(
                  ident("&"),
                  newStrLitNode(item.property.name & ": "),
                  nnkCall.newTree(
                    ident("validatePropertyValue"),
                    newStrLitNode(item.property.name),
                    item.property.body.node
                  )
                )
              )
        if inlineStyles.len > 0:
          echo "GOT INLINE STYLES: " & $inlineStyles.len
          for style in inlineStyles:
            echo "STYLE: " & style.treeRepr
            if parentStyles.kind == nnkEmpty:
              parentStyles = style
            else:
              parentStyles = parentStyles.concat(
                nnkInfix.newTree(
                  ident("&"),
                  newStrLitNode("; "),
                  style,
                )
              )
        
        echo "Final styles: " & parentStyles.repr
        
        var nodeResult = Result()
        if styleContent.kind != nnkEmpty:
          nodeResult.node =
            createElement("style", initTable[string, NimNode](), @[
              createTextElement(styleContent)
            ])
        
        if parentStyles.kind != nnkEmpty:
          nodeResult.attributeName = "style"
          nodeResult.attributeValue = parentStyles
        
        nodeResult.isQuotedAttribute = isQuoted
        return nodeResult


      var body:    NimNode = newEmptyNode()
      var textArg: NimNode = newEmptyNode()
      if callValue.kind == nnkStmtList:
        if node.len != 2:
          error "expected only 2 arguments, got " & $node.len, node

        body      = callValue
      elif callValue.kind in {nnkStrLit, nnkIdent}:
        if node.len == 3:
          if node[2].kind != nnkStmtList:
            error "expected a stmt list, got " & $node[2].kind, node[2]

          body    = node[2]
          textArg = callValue
        elif node.len == 2:
          textArg = callValue
        else:
          error "expected 2 or 3 arguments, got " & $node.len, node
      else:
        error "unexpected call value: " & $callValue.kind, callValue

      echo "------------------"
      if body.kind != nnkEmpty:
        var children: seq[NimNode] = @[]
        if textArg.kind != nnkEmpty:
          children.add createTextElement(textArg)

        var attributes: Table[string, NimNode] = initTable[string, NimNode]()
        var passthroughAttributes: seq[NimNode] = @[]

        var wasComponentSeq: NimNode = nnkPrefix.newTree(ident("@"), newTree(nnkBracket))

        # echo "HERE: " & callNodeName & " is " & $wasComponent
        for child in body:
          # echo "PROCESSING"
          echo child.treeRepr
          let childResult = process(child, false, not isElement)
          # if is element, expect all: elements, components, or attributes
          # if not is element, expect component inputs and passthrough attributes
          if isElement:
            if childResult.node != nil:
              children.add(childResult.node)
            
            if childResult.attributeName == "style":
              if childResult.isQuotedAttribute:
                error "Passthrough attributes are not allowed for elements", childResult.attributeValue

              var existingValue: NimNode = newEmptyNode()
              if attributes.hasKey(childResult.attributeName):
                existingValue = attributes[childResult.attributeName]
              if existingValue.kind != nnkEmpty:
                existingValue = nnkInfix.newTree(
                  ident("&"),
                  existingValue,
                  newStrLitNode("; "),
                )
                existingValue = nnkInfix.newTree(
                  ident("&"),
                  existingValue,
                  childResult.attributeValue,
                )
              else:
                existingValue = childResult.attributeValue
              attributes[childResult.attributeName] = existingValue
            
            elif childResult.attributeName != "":
              if childResult.isQuotedAttribute:
                error "Passthrough attributes are not allowed for elements", childResult.attributeValue

              if attributes.hasKey(childResult.attributeName):
                error "Duplicate attribute: " & childResult.attributeName, childResult.attributeValue
              attributes[childResult.attributeName] = childResult.attributeValue

          else:
            if childResult.node != nil:
              echo childResult.node.treeRepr
              if wasComponent:
                # we are a components inputs parsed node
                # attributes[callNodeName] = childResult.node
                wasComponentSeq[1].add(childResult.node)
              else:
                error "Unexpected node for component, expect inputs only: " & $childResult.node.kind, childResult.node
            if childResult.attributeName != "":
              # if isQuoted: passthrough attribute
              #   otherwise: is a component input
              
              if childResult.isQuotedAttribute:
                # echo "..."
                # TODO: here
                if isElement:
                  error "Passthrough attributes are only allowed for components", childResult.attributeValue
                # passthroughAttributes[childResult.attributeName] = childResult.attributeValue
                passthroughAttributes.add nnkTupleConstr.newTree(
                  newStrLitNode(childResult.attributeName),
                  childResult.attributeValue
                )
              else:
                attributes[childResult.attributeName] = childResult.attributeValue
        
        echo "GOT HERE: " & callNodeName & " : " & $isElement
        if wasComponent:
          return Result(
            attributeName: callNodeName,
            attributeValue: wasComponentSeq,
          )

        if isElement:
          return Result(
            node: createElement(elementName, attributes, children)
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

          echo "CALL: " & componentCall.repr

          if passthroughAttributes.len > 0:
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
            ])
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
  
  var topLevelResultingNodes: seq[NimNode] = @[]
  for child in body.children:
    let childResult = process(child, true)
    if childResult.attributeName != "":
      error "Attribute not allowed at root level: " & childResult.attributeName, childResult.attributeValue
    
    topLevelResultingNodes.add(childResult.node)
  
  var resultBody = nnkPrefix.newTree(
    ident("@"),
    nnkBracket.newTree(
      topLevelResultingNodes
    )
  )

  return (resultBody, eventHandlers)



macro web*(body: untyped): untyped =
  let (htmlResult, eventHandlers) = handleWeb(body, "none")

  if eventHandlers.len > 0:
    warning "web macro: Event handlers are not supported in this context."
    echo "Event handlers:"
    echo eventHandlers.repr
  
  result = htmlResult


macro addPassthroughAttributes*(body: untyped, passthroughAttributes: untyped): untyped =
  result = quote do:
    block:
      let body = `body`
      var resultBody: seq[HTMLNode] = @[]

      for node in body:
        var resultNode = node
        for attrName, attrValue in `passthroughAttributes`:
          # TODO: error on duplicate??
          # if node.attributes.hasKey(attrName):
          #   error "Duplicate attribute: " & attrName, node.attributes[attrName]
          
          if attrName == "style" and resultNode.attributes.hasKey("style"):
            resultNode.attributes["style"] = resultNode.attributes["style"] & "; " & attrValue
          else:
            resultNode.attributes[attrName] = attrValue
        resultBody.add(resultNode)

      resultBody


when isMainModule:
  proc component(name: string = ""): HTML =
    return web:
      p "This is a component!":
        style:
          color: red
      box:
        name
        # anything

  
  var test = "testing!!"
  let htmls = web:
    # p:
    #   id test
    #   someAttr "test"
    #   `test`
    #   # h1 "an h1"
    # h1 "Hello World!":
    #   style:
    #     color: red
    #     backgroundColor: blue

    #     !aSelector:
    #       color: red
    #   style:
    #     marginLeft: 1.px

    box:
      # `asdsad` "Dsad"
      component:
        name "testing"
        `anAttribute` "hello world"
        `style`:
          color: orange

        # anything:
          # h2 "An H2!"
          # h3 "An H333"

  echo "Final HTML:"
  echo htmls.treeRepr
  echo htmls