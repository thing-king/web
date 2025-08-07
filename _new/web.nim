import macros, tables, strutils, options
import html

# Types for processing
type
  NodeType = enum
    ntElement
    ntComponent
    ntText
    ntAttribute
    ntPassthrough
    ntBody
    ntStyle

  ProcessedNode = object
    case kind: NodeType
    of ntElement:
      tag: string
      attrs: Table[string, NimNode]
      children: seq[ProcessedNode]
    of ntComponent:
      name: string
      props: Table[string, NimNode]
      passthroughAttrs: seq[(string, NimNode)]
    of ntText:
      text: NimNode
    of ntAttribute:
      attrName: string
      attrValue: NimNode
    of ntPassthrough:
      passName: string
      passValue: NimNode
    of ntBody:
      bodyNodes: seq[ProcessedNode]
    of ntStyle:
      styleBlock: NimNode

  Context = object
    elementId: string
    isTopLevel: bool
    inComponent: bool
    elementCounter: int

# Helper functions
proc isHtmlElement(name: string): bool =
  let elemName = if name == "box": "div" else: name
  htmlElements.hasKey(elemName)

proc normalizeTag(name: string): string =
  if name == "box": "div" else: name

proc uniqueId(ctx: var Context): string =
  inc ctx.elementCounter
  if ctx.isTopLevel:
    ctx.elementId
  else:
    ctx.elementId & "-" & $ctx.elementCounter

# Main processing function
proc processNode(node: NimNode, ctx: var Context): ProcessedNode =
  case node.kind
  of nnkStrLit, nnkIntLit, nnkFloatLit:
    return ProcessedNode(kind: ntText, text: node)
  
  of nnkIdent:
    if ctx.inComponent:
      # In component context, could be attribute name or element
      if isHtmlElement(node.strVal):
        return ProcessedNode(kind: ntElement, tag: normalizeTag(node.strVal), 
                     attrs: initTable[string, NimNode](), children: @[])
      else:
        return ProcessedNode(kind: ntText, text: node)
    else:
      # Check if it's an HTML element
      if isHtmlElement(node.strVal):
        return ProcessedNode(kind: ntElement, tag: normalizeTag(node.strVal), 
                     attrs: initTable[string, NimNode](), children: @[])
      else:
        # It's a component
        return ProcessedNode(kind: ntComponent, name: node.strVal, 
                     props: initTable[string, NimNode](), passthroughAttrs: @[])
  
  of nnkAccQuoted:
    # treat `foo` as dynamic text, not a component
    let expr = node[0]
    return ProcessedNode(kind: ntText, text: expr)
  
  of nnkCall:
    if node.len < 1: 
      error("Invalid call node", node)
    
    let callName = node[0]
    
    # Handle different call patterns
    case callName.kind
    of nnkIdent:
      let name = callName.strVal
      
      if isHtmlElement(name):
        # HTML element with children or attributes
        result = ProcessedNode(kind: ntElement, tag: normalizeTag(name), 
                              attrs: initTable[string, NimNode](), children: @[])
        
        # Process arguments
        for i in 1..<node.len:
          let arg = node[i]
          case arg.kind
          of nnkStmtList:
            # Block of children/attributes
            var wasInComponent = ctx.inComponent
            ctx.inComponent = false
            for child in arg:
              let processed = processNode(child, ctx)
              case processed.kind
              of ntElement, ntComponent, ntText, ntBody:
                result.children.add(processed)
              of ntAttribute:
                result.attrs[processed.attrName] = processed.attrValue
              of ntPassthrough:
                error("Passthrough attributes not allowed on HTML elements", child)
              of ntStyle:
                # Handle style blocks later
                discard
            ctx.inComponent = wasInComponent
          
          of nnkExprEqExpr:
            # Named parameter (e.g., id = "test")
            let paramName = arg[0].strVal
            result.attrs[paramName] = arg[1]
          
          else:
            # Direct arguments (text or dynamic values)
            result.children.add(ProcessedNode(kind: ntText, text: arg))
      
      else:
        # Component call
        result = ProcessedNode(kind: ntComponent, name: name, 
                              props: initTable[string, NimNode](), passthroughAttrs: @[])
        
        # Process arguments
        for i in 1..<node.len:
          let arg = node[i]
          case arg.kind
          of nnkStmtList:
            # Block of props/children
            var wasInComponent = ctx.inComponent
            ctx.inComponent = true
            for child in arg:
              let processed = processNode(child, ctx)
              case processed.kind
              of ntAttribute:
                result.props[processed.attrName] = processed.attrValue
              of ntPassthrough:
                result.passthroughAttrs.add((processed.passName, processed.passValue))
              else:
                error("Unexpected node in component block", child)
            ctx.inComponent = wasInComponent
          
          of nnkExprEqExpr:
            # Named parameter
            let paramName = arg[0]
            if paramName.kind == nnkPrefix and paramName[0].strVal == "*":
              # Passthrough attribute (*id = "value")
              result.passthroughAttrs.add((paramName[1].strVal, arg[1]))
            else:
              result.props[paramName.strVal] = arg[1]
          
          of nnkPrefix:
            # Prefix expressions like *name "value"
            if arg[0].strVal == "*" and arg[1].kind == nnkCommand:
              let cmd = arg[1]
              result.passthroughAttrs.add((cmd[0].strVal, cmd[1]))
            else:
              error("Unexpected prefix expression", arg)
          
          else:
            # Positional arguments - need to map to component params
            # This would require knowing the component signature
            result.props[$i] = arg
    
    of nnkAccQuoted:
      # `component` call
      let name = callName[0].strVal
      result = ProcessedNode(kind: ntComponent, name: name, 
                            props: initTable[string, NimNode](), passthroughAttrs: @[])
      
      # Similar processing as above but for quoted component names
      for i in 1..<node.len:
        let arg = node[i]
        case arg.kind
        of nnkStmtList:
          var wasInComponent = ctx.inComponent
          ctx.inComponent = true
          for child in arg:
            let processed = processNode(child, ctx)
            case processed.kind
            of ntAttribute:
              result.props[processed.attrName] = processed.attrValue
            of ntPassthrough:
              result.passthroughAttrs.add((processed.passName, processed.passValue))
            else:
              error("Unexpected node in component block", child)
          ctx.inComponent = wasInComponent
        of nnkExprEqExpr:
          let paramName = arg[0]
          if paramName.kind == nnkPrefix and paramName[0].strVal == "*":
            result.passthroughAttrs.add((paramName[1].strVal, arg[1]))
          else:
            result.props[paramName.strVal] = arg[1]
        else:
          result.props[$i] = arg
    
    else:
      error("Unexpected call type", callName)
  
  of nnkCommand:
    # Handle commands like: p "text", id "value", *name "value"
    let cmdName = node[0]
    let cmdValue = node[1]
    
    case cmdName.kind
    of nnkIdent:
      let name = cmdName.strVal
      if isHtmlElement(name):
        # Simple element with text
        result = ProcessedNode(kind: ntElement, tag: normalizeTag(name), 
                              attrs: initTable[string, NimNode](), 
                              children: @[ProcessedNode(kind: ntText, text: cmdValue)])
      else:
        # Attribute
        result = ProcessedNode(kind: ntAttribute, attrName: name, attrValue: cmdValue)
    
    of nnkPrefix:
      # *attribute "value"
      if cmdName[0].strVal == "*":
        result = ProcessedNode(kind: ntPassthrough, 
                              passName: cmdName[1].strVal, 
                              passValue: cmdValue)
      else:
        error("Unexpected prefix in command", cmdName)
    
    else:
      error("Unexpected command type", cmdName)
  
  of nnkPrefix:
    # Handle prefix like *id "value"
    if node[0].strVal == "*" and node[1].kind == nnkCommand:
      let cmd = node[1]
      result = ProcessedNode(kind: ntPassthrough, 
                            passName: cmd[0].strVal, 
                            passValue: cmd[1])
    else:
      error("Unexpected prefix expression", node)
  
  else:
    error("Unsupported node kind: " & $node.kind, node)

# Convert ProcessedNode to NimNode
proc toNimNode(pnode: ProcessedNode, ctx: var Context): NimNode =
  case pnode.kind
  of ntElement:
    let elemId = ctx.uniqueId()
    
    # Build HTMLNode constructor
    result = nnkObjConstr.newTree(
      ident("HTMLNode"),
      nnkExprColonExpr.newTree(ident("kind"), ident("htmlnkElement")),
      nnkExprColonExpr.newTree(ident("tag"), newStrLitNode(pnode.tag)),
      nnkExprColonExpr.newTree(ident("elementId"), newStrLitNode(elemId))
    )
    
    var attrPairs = nnkBracket.newTree()
    # inject our thing-element-id
    attrPairs.add nnkTupleConstr.newTree(
      newStrLitNode("thing-element-id"),
      newStrLitNode(elemId)
    )
    # Add attributes if any
    if pnode.attrs.len > 0:
      for key, value in pnode.attrs:
        attrPairs.add(nnkTupleConstr.newTree(newStrLitNode(key), value))
      
    result.add(nnkExprColonExpr.newTree(
      ident("attributes"),
      nnkCall.newTree(
        ident("newTable"),
        nnkPrefix.newTree(ident("@"), attrPairs)
      )
      # nnkDotExpr.newTree(
      #   nnkPrefix.newTree(ident("@"), attrPairs),
      #   ident("toTable")
      # )
    ))
    
    # Add children if any
    if pnode.children.len > 0:
      var childrenArray = nnkBracket.newTree()
      for child in pnode.children:
        childrenArray.add(toNimNode(child, ctx))
      
      result.add(nnkExprColonExpr.newTree(
        ident("children"),
        nnkPrefix.newTree(ident("@"), childrenArray)
      ))
  
  of ntComponent:
    # Build component call
    result = nnkCall.newTree(ident(pnode.name))
    
    # Add props
    for key, value in pnode.props:
      result.add(nnkExprEqExpr.newTree(ident(key), value))
    
    # Wrap with toBody
    result = nnkCall.newTree(ident("toBody"), result)
    
    # Add passthrough attributes if any
    if pnode.passthroughAttrs.len > 0:
      var attrPairs = nnkBracket.newTree()
      for (key, value) in pnode.passthroughAttrs:
        attrPairs.add(nnkTupleConstr.newTree(newStrLitNode(key), value))
      
      result = nnkCall.newTree(
        ident("addPassthroughAttributes"),
        result,
        nnkDotExpr.newTree(
          nnkPrefix.newTree(ident("@"), attrPairs),
          ident("toTable")
        )
      )
  
  of ntText:
    result = nnkObjConstr.newTree(
      ident("HTMLNode"),
      nnkExprColonExpr.newTree(ident("kind"), ident("htmlnkText")),
      nnkExprColonExpr.newTree(ident("text"), pnode.text)
    )
  
  of ntBody:
    var bodyArray = nnkBracket.newTree()
    for node in pnode.bodyNodes:
      bodyArray.add(toNimNode(node, ctx))
    result = nnkPrefix.newTree(ident("@"), bodyArray)
  
  else:
    error("Cannot convert node type to NimNode: " & $pnode.kind)

# Helper to convert body of nodes to HTML
proc toBody*(html: HTML): HTML = html

# Main web macro
macro web*(body: untyped): untyped =
  var ctx = Context(elementId: "web", isTopLevel: true, inComponent: false, elementCounter: 0)
  # require at least one child
  # static: assert(body.len > 0, "web: empty body")
  # seed acc with the first
  let firstProcessed = processNode(body[0], ctx)
  var acc: NimNode = if firstProcessed.kind == ntComponent:
    toNimNode(firstProcessed, ctx)
  else:
    nnkPrefix.newTree(ident("@"), nnkBracket.newTree(toNimNode(firstProcessed, ctx)))
  # fold the rest
  for i in 1..<body.len:
    let p = processNode(body[i], ctx)
    let item = if p.kind == ntComponent:
      toNimNode(p, ctx)
    else:
      nnkPrefix.newTree(ident("@"), nnkBracket.newTree(toNimNode(p, ctx)))
    acc = nnkInfix.newTree(ident("&"), acc, item)
  result = acc


# Passthrough attributes handler (simplified for now)
proc addPassthroughAttributes*(body: HTML, attrs: Table[string, string]): HTML =
  result = body
  for node in result:
    if node.kind == htmlnkElement:
      for key, value in attrs:
        node.attributes[key] = value


when isMainModule:
  proc aComponent(name: string): HTML =
    return web:
      p "This is a component!"
      p "Anotha one!"
      p `name`

  let dynamicValue = "Dynamic content"

  proc onMouseOver() =
    echo "Mouse over event triggered!"

  let htmls = web:
    p `dynamicValue`
    h1:
      `dynamicValue`
    
    box(name = `dynamicValue`):
      p "Test"
      

    p "Hello world!"
    p: "Hello world 2"
    p:
      "A"
      "B"
      "C"

    aComponent:
      name "str"
      *id "test-id"

    # `aComponent`


    # box:
    #   h1:
    #     "H1!"
    #     name "test"
    #   p("Test1", "test2", box("Nested box")) # undeclared identifier: 'box'
       
        # *id "an id", this errors appropriately
        # class: "an id"  # this errors, 'Unexpected node in component block'
      
      # p("Test", id = "testing", *name = "test")  # node lacks field: strVal at line 137 `let paramName = arg[0].strVal`



  echo htmls