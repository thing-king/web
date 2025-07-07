import macros
import strutils, tables, options

import html
export html

import thing/thing_seed/src/thing_seed/dom
import jsony_plus

import essentials


# Logging
const LOG_ENABLED = false
macro logState(args: varargs[untyped]): untyped =
  when LOG_ENABLED:
    return quote do:
      block:
        var msg = ""
        for arg in `args`:
          msg &= $arg & " "
        echo msg
  else:
    return newEmptyNode()

when defined(js):
  when LOG_ENABLED:
    {.emit: "window._state_log_enabled = true"}
  else:
    {.emit: "window._state_log_enabled = false"}
  {.emit: """
  window.stateLog = function(...args) {
    if (window._state_log_enabled) {
      console.log('[StateLog]', ...args);
    }
  };
  """}



proc getBuiltinJS*(): string =
  return """
window._eventListeners = [];

const originalAddEventListener = window.addEventListener;
const originalRemoveEventListener = window.removeEventListener;

window.addEventListener = function (type, listener, options) {
    window._eventListeners.push({ target: this, type, listener, options });
    originalAddEventListener.call(this, type, listener, options);
};

window.removeEventListener = function (type, listener, options) {
    window._eventListeners = window._eventListeners.filter(event => 
        !(event.target === this && event.type === type && event.listener === listener)
    );
    originalRemoveEventListener.call(this, type, listener, options);
};

window.getAllEventListeners = function () {
    return window._eventListeners;
};

window.removeAllEventListeners = function () {
    window._eventListeners.forEach(event => {
        event.target.removeEventListener(event.type, event.listener, event.options);
    });
    window._eventListeners = [];
};

window.removeAllDOMEventListeners = function () {
    const domEvents = window._eventListeners.filter(event => 
        event.type.includes(':')
    );
    
    domEvents.forEach(event => {
        event.target.removeEventListener(event.type, event.listener, event.options);
    });
    
    window._eventListeners = window._eventListeners.filter(event => 
        !event.type.includes(':')
    );
};

window.removeComponentDOMEventListeners = function (componentInstanceId) {
    const componentDomEvents = window._eventListeners.filter(event => 
        event.type.includes(':') && event.type.includes(componentInstanceId)
    );
    
    componentDomEvents.forEach(event => {
        event.target.removeEventListener(event.type, event.listener, event.options);
    });
    
    window._eventListeners = window._eventListeners.filter(event => 
        !(event.type.includes(':') && event.type.includes(componentInstanceId))
    );
};


(function() {
  const debug = false;
  const wsUrl = 'ws://localhost:5001';
  const reconnectDelay = 250;
  const pingInterval = 250;
  const pingTimeout = 500;
  
  let socket;
  let pingTimer;
  let pongTimer;
  let isConnectionLost = false;
  let isInitialConnection = true;
  
  function connect() {
    socket = new WebSocket(wsUrl);
    
    socket.onopen = () => {
      if (debug) {
        console.log('[DevReload] Connected to reload server');
      }
      
      if (isConnectionLost && !isInitialConnection) {
        if (debug) {
          console.log('[DevReload] Server is back online, refreshing page...');
        }
        window.location.reload();
      }
      
      isInitialConnection = false;
      isConnectionLost = false;
      
      startPing();
    };
    
    socket.onmessage = (event) => {
      if (event.data === 'reload') {
        window.location.reload();
        return;
      }
      
      if (event.data === 'pong') {
        if (debug) {
          console.log('[DevReload] Received pong');
        }
        clearTimeout(pongTimer);
      }
    };
    
    socket.onclose = () => {
      if (debug) {
        console.log('[DevReload] Connection to reload server closed, reconnecting...');
      }
      
      cleanup();
      isConnectionLost = true;
      setTimeout(connect, reconnectDelay);
    };
    
    socket.onerror = () => {
      if (debug) {
        console.log('[DevReload] Error connecting to reload server, will retry...');
      }
      
      cleanup();
      isConnectionLost = true;
      socket.close();
    };
  }
  
  function startPing() {
    clearInterval(pingTimer);
    
    pingTimer = setInterval(() => {
      if (socket.readyState === WebSocket.OPEN) {
        if (debug) {
          console.log('[DevReload] Sending ping');
        }
        
        socket.send('ping');
        
        clearTimeout(pongTimer);
        pongTimer = setTimeout(() => {
          if (debug) {
            console.log('[DevReload] Pong timeout - connection is dead');
          }
          
          cleanup();
          isConnectionLost = true;
          socket.close();
          setTimeout(connect, reconnectDelay);
        }, pingTimeout);
      }
    }, pingInterval);
  }
  
  function cleanup() {
    clearInterval(pingTimer);
    clearTimeout(pongTimer);
  }
  
  connect();
})();
"""

var pageComponent* {.used, threadvar.}: Option[proc(): HTML]
var pageComponentName* {.used, threadvar.}: string
proc clearPageComponent*() =
  pageComponent = none(proc(): HTML)
  pageComponentName = ""
proc setPageComponent*(component: proc(): HTML, name: string) =
  pageComponent = some(component)
  pageComponentName = name


var serverSideState* {.used, threadvar.}: Table[string, Table[string, string]]
proc initServerSideState*() =
  serverSideState = initTable[string, Table[string, string]]()
initServerSideState()

proc getServerSideState*(): Table[string, Table[string, string]] =
  return serverSideState


var effectDeps* {.used, threadvar.}: Table[string, seq[string]]
proc initEffectDeps*() =
  effectDeps = initTable[string, seq[string]]()
initEffectDeps()

proc getEffectDeps*(): Table[string, seq[string]] =
  return effectDeps


var memoValues* {.used, threadvar.}: Table[string, (string, seq[string])]
proc initMemoValues*() =
  memoValues = initTable[string, (string, seq[string])]()
initMemoValues()

proc getMemoValues*(): Table[string, (string, seq[string])] =
  return memoValues




proc stateInitEnabled*(): bool =
  when defined(js):
    {.emit: "return window._state_init_enabled"}
  else:
    # TODO: ?
    return true
proc eventInitEnabled*(): bool =
  when defined(js):
    {.emit: "return window._event_init_enabled"}
  else:
    # TODO: ?
    return true





proc useMemo*[T](componentInstanceId: string, key: string, callback: Procedure[proc(): T], deps: openArray[string]): int =
  when defined(js):
    if memoValues.hasKey(componentInstanceId & "-" & key):
      let (lastValueStr, lastDeps) = memoValues[componentInstanceId & "-" & key]
      if lastDeps == deps:
        return parse[T](lastValueStr)
    
    let value = callback()
    let valueStr = value.toJson()
    memoValues[componentInstanceId & "-" & key] = (valueStr, @deps)
    return value
  else:
    logState("not-js, useMemo", componentInstanceId, key)
    return 0


var effectListeners* {.used, threadvar.}: Table[string, Table[string, seq[(EventTarget, string, proc(ev: Event))]]]
proc initEffectListeners() =
  effectListeners = initTable[string, Table[string, seq[(EventTarget, string, proc(ev: Event))]]]()
initEffectListeners()
proc addEventListener*(componentId: string, effectId: string, et: EventTarget, ev: string, cb: proc(ev: Event), useCapture: bool = false) =
  if not effectListeners.hasKey(effectId):
    effectListeners[effectId] = initTable[string, seq[(EventTarget, string, proc(ev: Event))]]()
  if not effectListeners[effectId].hasKey(componentId):
    effectListeners[effectId][componentId] = @[]
  effectListeners[effectId][componentId].add((et, ev, cb))
  et.addEventListener(ev, cb, useCapture)
proc addEventListener*(componentId: string, effectId: string, et: EventTarget, ev: string, cb: proc (ev: Event), options: AddEventListenerOptions) =
  if not effectListeners.hasKey(effectId):
    effectListeners[effectId] = initTable[string, seq[(EventTarget, string, proc(ev: Event))]]()
  if not effectListeners[effectId].hasKey(componentId):
    effectListeners[effectId][componentId] = @[]
  effectListeners[effectId][componentId].add((et, $ev, cb))
  et.addEventListener(ev, cb, options)
proc clearEffectEventListeners(componentId: string, effectId: string) =
  if effectListeners.hasKey(effectId) and effectListeners[effectId].hasKey(componentId):
    for (et, ev, cb) in effectListeners[effectId][componentId]:
      et.removeEventListener(ev, cb)
    effectListeners[effectId].del(componentId)

proc useEffect*(componentInstanceId: string, effectId: string, callback: Procedure[proc()]) =
  # TODO: this needs to happen after render?
  when defined(js):
    clearEffectEventListeners(componentInstanceId, effectId)
    callback()

proc useEffect*(componentInstanceId: string, effectId: string, jsCallback: string) =
  when defined(js):
    {.emit: "window.eval(`jsCallback`)"}
  else:
    discard

proc doCallEffect(componentInstanceId: string, effectId: string, deps: openArray[string]): bool =
  when defined(js):
    if deps.len == 0:
      if eventInitEnabled():
        return true
    else:
      if effectDeps.hasKey(componentInstanceId & "-" & effectId):
        let lastDeps = effectDeps[componentInstanceId & "-" & effectId]
        if lastDeps != deps:
          effectDeps[componentInstanceId & "-" & effectId] = @deps
          return true
      else:
        effectDeps[componentInstanceId & "-" & effectId] = @deps
        return true
  else:
    if deps.len == 0:
      if eventInitEnabled():
        return true
  return false

proc useEffect*[T](componentInstanceId: string, effectId: string, callback: Procedure[T], deps: openArray[string]) =
  if doCallEffect(componentInstanceId, effectId, deps):
    clearEffectEventListeners(componentInstanceId, effectId)
    discard dom.setTimeout(proc() =
      callback()
    , 0)


proc useEffect*(componentInstanceId: string, effectId: string, jsCallback: string, deps: openArray[string]) =
  # no event clearing
  if doCallEffect(componentInstanceId, effectId, deps):
    when defined(js):
      {.emit: "window.eval(String.fromCharCode(...`jsCallback`));"}
    else:
      discard

proc initState*[T](componentInstanceId: string, key: string, value: T) =
  let str = value.toJson()
  when defined(js):
    {.emit: "window.initState(`componentInstanceId`, `key`, `str`)"}
  else:
    # echo "not-js, initState", componentInstanceId, key, intNum
    logState("not-js, initState", componentInstanceId, key, str)
    if not serverSideState.hasKey(componentInstanceId):
      serverSideState[componentInstanceId] = initTable[string, string]()
    serverSideState[componentInstanceId][key] = str



proc getStrState*(componentInstanceId: string, key: string): string =
  when defined(js):
    {.emit: "return window.getState(`componentInstanceId`, `key`)"}
  else:
    logState("not-js, getState", componentInstanceId, key)
    return serverSideState[componentInstanceId][key]



proc getState*[T](componentInstanceId: string, key: string): T =
  let str = getStrState(componentInstanceId, key)
  return fromJson(str, T)

proc setState*[T](componentInstanceId: string, key: string, value: T) =
  let jsonString = value.toJson()
  when defined(js):
    {.emit: "window.setState(`componentInstanceId`, `key`, `jsonString`)"}
  else:
    logState("not-js, setState", componentInstanceId, key, value)
    serverSideState[componentInstanceId][key] = jsonString



# proc setState*[T](componentInstanceId: string, value: T) =
#   {.emit: "window._state[`componentInstanceId`] = `value`;"}


proc useState*[T](componentInstanceId: string, key: string, value: T): (T, proc(n: T), proc(cb: proc(cur: T): T = nil): void) =
  initState(componentInstanceId, key, value)
  when defined(js):
    # {.emit: "window.initState(`componentInstanceId`, `key`, `intNum`)"}


    return (
      getState[T](componentInstanceId, key),
      proc(n: T) = 
        setState(componentInstanceId, key, n)
      ,
      proc(cb: proc(cur: T): T = nil) =
        let cur = getState[T](componentInstanceId, key)
        let nn = cb(cur)
        setState(componentInstanceId, key, nn)
    )
  else:
    # echo "not-js, useState", componentInstanceId, key, intNum
    # serverSideState[componentInstanceId & "-" & key] = %intNum
    
    return (
      parse[T](serverSideState[componentInstanceId][key]),
      proc(n: T) =
        serverSideState[componentInstanceId][key] = n.toJson()
      ,
      proc(cb: proc(cur: T): T = nil): void =
        let cur = parse[T](serverSideState[componentInstanceId][key])
        let nn = cb(cur)
        serverSideState[componentInstanceId][key] = nn.toJson()
    )






when defined(js):
  import util

  {.emit: "if(!window._state) window._state = {}"}
  {.emit: "window._state_init_enabled = false"}
  {.emit: "window._event_init_enabled = false"}

  {.emit: """
window._pendingUpdates = new Set();
window._isBatchingUpdates = false;
window._batchTimeout = null;

window.flushStateUpdates = function() {
  if (window._pendingUpdates.size === 0) {
    window._isBatchingUpdates = false;
    window._batchTimeout = null;
    return;
  }
  
  window.stateLog('Flushing', window._pendingUpdates.size, 'batched state updates');
  
  // Clear the pending updates before rendering to avoid infinite loops
  const componentsToUpdate = Array.from(window._pendingUpdates);
  window._pendingUpdates.clear();
  window._isBatchingUpdates = false;
  window._batchTimeout = null;
  
  // Trigger a single re-render for all updated components
  // For now, we'll just trigger one render since the framework does full page renders
  // In a more sophisticated framework, you could render only affected components
  if (componentsToUpdate.length > 0) {
    window.onStateUpdated(componentsToUpdate[0]); // Use first component as trigger
  }
};

window.scheduleStateUpdate = function(componentInstanceId) {
  window._pendingUpdates.add(componentInstanceId);
  
  if (!window._isBatchingUpdates) {
    window._isBatchingUpdates = true;
    // Use setTimeout(0) to defer to next tick, allowing multiple setState calls to batch
    window._batchTimeout = setTimeout(window.flushStateUpdates, 0);
  }
};
"""}

  {.emit: """
window.initState = function(componentInstanceId, key, value) {
  if(!window._state_init_enabled) {
    window.stateLog('initState unavailable', componentInstanceId, key, value);
  } else {
    window.stateLog('initState', componentInstanceId, key, value);
    if (window._state[componentInstanceId] == undefined) {
      window._state[componentInstanceId] = {}
    }
    window._state[componentInstanceId][key] = value;
  }
}"""}
  {.emit: """
window.getState = function(componentInstanceId, key) {
  window.stateLog('getState', componentInstanceId, key);
  try {
    return window._state[componentInstanceId][key]
  } catch (error) {
    console.log(error);
    throw new Error('State not found: ' + componentInstanceId + ' ' + key)
  }
}"""}
  {.emit: """
window.setState = function(componentInstanceId, key, value) {
  window.stateLog('setState', componentInstanceId, key, value);
  let preVal = window._state[componentInstanceId][key]
  window._state[componentInstanceId][key] = value;

  let hasChanged = false
  
  let preValArray = Array.isArray(preVal)
  let valueArray = Array.isArray(value)
  if(valueArray || preValArray) {
    if (preValArray && valueArray) {
      if (preVal.length != value.length) {
        hasChanged = true
      } else {
        for (let i = 0; i < preVal.length; i++) {
          if (preVal[i] != value[i]) {
            hasChanged = true
            break
          }
        }
      }
    } else {
      hasChanged = true
    }
  } else {
    if (preVal != value) {
      hasChanged = true
    }
  }

  if (hasChanged) {
    // Instead of immediately calling onStateUpdated, schedule a batched update
    window.scheduleStateUpdate(componentInstanceId);
  }
}"""}



  proc hasDOM*(): bool =
    {.emit: "return window._dom != undefined"}

  proc getPreviousDOM*(): HTML =
    {.emit: "return window._dom"}

  proc isSSR*(): bool =
    {.emit: "return window._ssr"}

  proc render*(html: HTML, fullRender: bool = false) =
    proc doStartAtBody(html: HTML): bool =
      return html[0].tag notin ["html", "head", "body"]
    let startAtBody = html.doStartAtBody()

    # Define void elements that cannot have children
    const voidElements = ["area", "base", "br", "col", "embed", "hr", "img", 
                        "input", "link", "meta", "source", "track", "wbr"]

    # if no previous DOM, or forced full render -> do full render
    if not hasDOM() or fullRender:
      logState("Performing full render")
      if not startAtBody:
        var htmlBody = html

        # If <html> get children
        # TODO: enforce this in HTML DSL
        if html[0].tag == "html":
          htmlBody = html[0].children

        for node in htmlBody:
          if node.tag == "head":
            logState("Setting head innerHTML")
            document.head.innerHTML = $node & $document.head.innerHTML
          elif node.tag == "body":
            logState("Setting body innerHTML")
            document.body.innerHTML = $node
          else:
            # TODO: this should work
            {.emit: "throw new Error('Encountered complex HTML that is not <head> or <body>')"}
      else:
        logState("Setting body innerHTML for startAtBody")
        document.body.innerHTML = $html
    else:
      logState("Performing differential render")
      
      # Store previous DOM for comparison
      let previousDOM = getPreviousDOM()
      
      proc compareHTMLNodes(a: HTMLNode, b: HTMLNode): bool =
        if a.kind != b.kind:
          logState("Node kind differs:", $a.kind, "vs", $b.kind)
          return false
          
        case a.kind:
        of htmlnkText:
          if a.text != b.text:
            logState("Text content differs:", a.text, "vs", b.text)
            return false
        of htmlnkElement:
          if a.tag != b.tag:
            logState("Tag differs:", a.tag, "vs", b.tag)
            return false
            
          # Compare attributes more carefully
          if a.attributes.len != b.attributes.len:
            logState("Attribute count differs:", $a.attributes.len, "vs", $b.attributes.len)
            return false
            
          # Check each attribute
          for key, value in a.attributes:
            if not b.attributes.hasKey(key):
              logState("Missing attribute in new node:", key)
              return false
            if b.attributes[key] != value:
              logState("Attribute value differs for", key & ":", value, "vs", b.attributes[key])
              return false
              
          # Check for extra attributes in b
          for key in b.attributes.keys:
            if not a.attributes.hasKey(key):
              logState("Extra attribute in new node:", key)
              return false
              
          # Compare children
          if a.children.len != b.children.len:
            logState("Children count differs:", $a.children.len, "vs", $b.children.len)
            return false
            
          for i in 0..<a.children.len:
            if not compareHTMLNodes(a.children[i], b.children[i]):
              return false
        
        return true
      
      # Enhanced virtual DOM comparison before doing any DOM manipulation
      proc compareVirtualDOM(prev: HTML, curr: HTML): bool =
        if prev.len != curr.len:
          logState("Virtual DOM length differs:", $prev.len, "vs", $curr.len)
          return false
          
        for i in 0..<prev.len:
          if not compareHTMLNodes(prev[i], curr[i]):
            logState("Virtual DOM node differs at index:", $i)
            return false
        return true
      
      
      # Check if virtual DOM actually changed
      if compareVirtualDOM(previousDOM, html):
        logState("Virtual DOM unchanged, skipping render")
        {.emit: "window._dom = `html`"}  # Still update the stored DOM
        return
      
      logState("Virtual DOM changed, proceeding with differential render")

      # find differences
      proc createNode(htmlNode: HTMLNode): Node =
        case htmlNode.kind
        of htmlnkElement:
          let node = document.createElement(htmlNode.tag)
          for attrName, attrValue in htmlNode.attributes:
            node.setAttribute(attrName, attrValue)
          
          # Only append children to non-void elements
          if htmlNode.tag.toLowerAscii notin voidElements:
            for child in htmlNode.children:
              node.appendChild(createNode(child))
          
          return node
        of htmlnkText:
          return document.createTextNode(htmlNode.text)

      proc getRelevantChild(parent: Node, index: int): Node =
        # Get the index-th relevant child (Element or Text node)
        var count = 0
        for child in parent.childNodes:
          if child.nodeType == ElementNode or child.nodeType == TextNode:
            if count == index:
              return child
            inc count
        return nil

      proc getRelevantChildCount(parent: Node): int =
        # Count relevant children (Element or Text nodes)
        var count = 0
        for child in parent.childNodes:
          if child.nodeType == ElementNode or child.nodeType == TextNode:
            inc count
        return count

      proc check(previousDOM: HTML, html: HTML, parent: Node = nil, depth: int = 0) =
        let indent = repeat("  ", depth)
        logState(indent & "Checking level with", $previousDOM.len, "old nodes and", $html.len, "new nodes")
        
        let oldCount = previousDOM.len
        let newCount = html.len
        
        # Get current DOM child count for comparison
        let domCount = if parent == nil:
          if startAtBody: 
            getRelevantChildCount(document.body)
          else: 
            getRelevantChildCount(document.documentElement)
        else:
          getRelevantChildCount(parent)
        
        logState(indent & "DOM has", $domCount, "relevant children")

        for i in 0..<max(max(oldCount, newCount), domCount):
          # Remove extra nodes from DOM
          if i >= newCount:
            let nodeEl = if parent == nil:
              if startAtBody: 
                getRelevantChild(document.body, i)
              else: 
                getRelevantChild(document.documentElement, i)
            else: 
              getRelevantChild(parent, i)
            
            if nodeEl != nil and nodeEl.parentNode != nil:
              logState(indent & "Removing child node at index", $i)
              nodeEl.parentNode.removeChild(nodeEl)
            continue

          let newNode = html[i]
          var oldNode: Option[HTMLNode] = none(HTMLNode)
          if i < oldCount:
            oldNode = some(previousDOM[i])

          var nodeEl: Node
          if parent == nil:
            nodeEl = if startAtBody: 
              getRelevantChild(document.body, i)
            else: 
              getRelevantChild(document.documentElement, i)
          else:
            nodeEl = getRelevantChild(parent, i)

          # If no existing node, create and append new one
          if nodeEl == nil:
            logState(indent & "Creating and appending new node at index", $i)
            let newNodeEl = createNode(newNode)
            if parent == nil:
              if startAtBody:
                document.body.appendChild(newNodeEl)
              else:
                document.documentElement.appendChild(newNodeEl)
            else:
              parent.appendChild(newNodeEl)
            continue

          # Enhanced node comparison with debugging
          let needsReplacement = block:
            if oldNode.isNone:
              logState(indent & "No old node to compare at index", $i)
              true
            elif oldNode.get.kind != newNode.kind:
              logState(indent & "Node kind mismatch at index", $i, ":", $oldNode.get.kind, "vs", $newNode.kind)
              true
            elif newNode.kind == htmlnkElement and oldNode.get.tag != newNode.tag:
              logState(indent & "Tag mismatch at index", $i, ":", oldNode.get.tag, "vs", newNode.tag)
              true
            else:
              false
          
          if needsReplacement:
            logState(indent & "Replacing node at index", $i, "due to type/tag mismatch")
            let newNodeEl = createNode(newNode)
            nodeEl.parentNode.replaceChild(newNodeEl, nodeEl)
            continue

          # Handle text nodes
          if newNode.kind == htmlnkText:
            if nodeEl.nodeType != TextNode:
              logState(indent & "Replacing node with text node at index", $i)
              let newNodeEl = document.createTextNode(newNode.text)
              nodeEl.parentNode.replaceChild(newNodeEl, nodeEl)
            elif nodeEl.textContent != newNode.text:
              logState(indent & "Updating text content at index", $i, "from:", nodeEl.textContent, "to:", newNode.text)
              nodeEl.textContent = newNode.text
            else:
              logState(indent & "Text content unchanged at index", $i)
          
          # Handle element nodes
          elif newNode.kind == htmlnkElement:
            var attributeChanged = false
            
            # Normalize attribute values - treat null and empty string as equivalent
            proc normalizeAttrValue(value: cstring): string =
              if value == nil or $value == "null" or $value == "":
                return ""
              else:
                return $value
            
            proc safeGetAttribute(node: Node, attrName: string): cstring =
              {.emit: """
              var attr = `node`.getAttribute(`attrName`);
              return attr === null ? "" : attr;
              """.}
            
            # Diff attributes with detailed logging
            for k, v in newNode.attributes:
              let currentValue = normalizeAttrValue(safeGetAttribute(nodeEl, k))
              let normalizedNewValue = normalizeAttrValue(cstring(v))
              let oldValue = if oldNode.isSome: 
                normalizeAttrValue(cstring(oldNode.get.attributes.getOrDefault(k, "")))
              else: 
                ""
              
              # More precise attribute comparison - only set if actually different
              if currentValue != normalizedNewValue:
                # Only setAttribute if the new value is not empty
                if normalizedNewValue != "":
                  logState(indent & "Setting attribute", k, "to", normalizedNewValue, "at index", $i, "(current DOM value:", currentValue, ", old virtual value:", oldValue, ")")
                  nodeEl.setAttribute(k, normalizedNewValue)
                  attributeChanged = true
                else:
                  # Remove attribute if new value is empty/null
                  if currentValue != "":
                    logState(indent & "Removing attribute", k, "at index", $i, "(was:", currentValue, ")")
                    nodeEl.removeAttribute(k)
                    attributeChanged = true
                  else:
                    logState(indent & "Attribute", k, "remains unset at index", $i)
              else:
                logState(indent & "Attribute", k, "unchanged at index", $i, "(normalized value:", normalizedNewValue, ")")
            
            # Remove attributes that no longer exist
            if oldNode.isSome:
              for k in oldNode.get.attributes.keys:
                if not newNode.attributes.hasKey(k):
                  logState(indent & "Removing attribute", k, "at index", $i)
                  nodeEl.removeAttribute(k)
                  attributeChanged = true
            
            if not attributeChanged:
              logState(indent & "No attribute changes detected at index", $i)
            
            # Recursively check children only for non-void elements
            if newNode.tag.toLowerAscii notin voidElements:
              let oldChildren = if oldNode.isSome: oldNode.get.children else: @[]
              check(oldChildren, newNode.children, nodeEl, depth + 1)
            else:
              logState(indent & "Skipping children for void element:", newNode.tag, "at index", $i)

      # Start the diffing process
      check(previousDOM, html)

    {.emit: "window._dom = `html`"}
    {.emit: "window._state_init_enabled = false"}
    {.emit: "window._event_init_enabled = false"}

  proc renderAll*() =
    logState("Rendering page '" & pageComponentName & "'")
    # log "page: " & pageComponentName

    {.emit: "window._state_init_enabled = true"}
    {.emit: "window._event_init_enabled = true"}
    {.emit: "window.removeAllEventListeners()"}
    render(
      (pageComponent.get())()
    )

  const ALWAYS_FORCE_FULL_RENDER = false

  proc onStateUpdated*(componentInstanceId: string) =
    logState "State updated for: ", componentInstanceId, "\nAttempting render..."
    # TODO: contemplate grabbing `web thing` for componentInstanceId and rendering from there

    # {.emit: "window.removeAllEventListeners()"} # TODO: disabled for useEffect event listener overlap
    {.emit: "window.removeAllDOMEventListeners()"}
    render(
      (pageComponent.get())(),
      ALWAYS_FORCE_FULL_RENDER
    )

  document.addEventListener("DOMContentLoaded", proc(ev: Event) =
    if isSSR():
      # {.emit: "window._state_init_enabled = true"}
      {.emit: "window._event_init_enabled = true"}
      {.emit: "window.removeAllEventListeners()"}
      discard (pageComponent.get())()
      # {.emit: "window._state_init_enabled = false"}
      {.emit: "window._event_init_enabled = false"}

    else:
      renderAll()
  )

  attachToWindow "renderAll", renderAll
  attachToWindow "onStateUpdated", onStateUpdated

