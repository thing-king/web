import macros
import strutils, sequtils, tables, options

import times

import html
export html

import thing/thing_seed/src/thing_seed/dom
import jsony_plus

import essentials


# Logging
const LOG_ENABLED = false
macro logState(args: varargs[untyped]): untyped =
  when LOG_ENABLED:
    proc toStrLit(node: NimNode): NimNode =
      if node.kind == nnkStrLit:
        return node
      else:
        return nnkPrefix.newTree(
          ident("$"),
          node
        )
    var node = toStrLit(args[0])
    if args.len > 1:
      for i in 1..<args.len:
        node = nnkInfix.newTree(
          ident("&"),
          nnkInfix.newTree(
            ident("&"),
            node,
            newStrLitNode(",  ")
          ),
          toStrLit(args[i])
        )
    return quote do:
      block:
        echo `node`
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
      const convertedArgs = args.map(arg =>
        Array.isArray(arg) && arg.every(n => Number.isInteger(n)) 
          ? String.fromCharCode(...arg)
          : arg
      );
      console.log('[StateLog]', ...convertedArgs);
    }
  };
  """}



proc getBuiltinJS*(): string =
  return """
window._eventListeners = [];
window._initializedStateComponentInstances = new Map();
window._initializedEffectComponentInstances = new Map();

window.isComponentInstanceStateInitialized = function (rawComponentInstanceId, rawStateKey) {
  let componentInstanceId = String.fromCharCode(...rawComponentInstanceId);
  let stateKey = String.fromCharCode(...rawStateKey);

  // if window._state already has an entry, return true (ssr initialized)
  if (window._state && window._state[rawComponentInstanceId] && window._state[rawComponentInstanceId][rawStateKey] !== undefined) {
    return true;
  }

  if(window._initializedStateComponentInstances.has(componentInstanceId)) {
    let stateKeys = window._initializedStateComponentInstances.get(componentInstanceId);
    if (stateKeys && stateKeys.has(stateKey)) {
      return true;
    }
  }
  return false;
};
window.isComponentInstanceEffectInitialized = function (rawComponentInstanceId, rawEffectId) {
  let componentInstanceId = String.fromCharCode(...rawComponentInstanceId);
  let effectId = String.fromCharCode(...rawEffectId);

  if(window._initializedEffectComponentInstances.has(componentInstanceId)) {
    let effectIds = window._initializedEffectComponentInstances.get(componentInstanceId);
    if (effectIds && effectIds.has(effectId)) {
      return true;
    }
  }
  return false;
};
window.setComponentInstanceStateInitialized = function (rawComponentInstanceId, rawStateKey) {
  let componentInstanceId = String.fromCharCode(...rawComponentInstanceId);
  let stateKey = String.fromCharCode(...rawStateKey);

  if (!window._initializedStateComponentInstances.has(componentInstanceId)) {
    window._initializedStateComponentInstances.set(componentInstanceId, new Set());
  }
  window._initializedStateComponentInstances.get(componentInstanceId).add(stateKey);
};
window.setComponentInstanceEffectInitialized = function (rawComponentInstanceId, rawEffectId) {
  let componentInstanceId = String.fromCharCode(...rawComponentInstanceId);
  let effectId = String.fromCharCode(...rawEffectId);

  if (!window._initializedEffectComponentInstances.has(componentInstanceId)) {
    window._initializedEffectComponentInstances.set(componentInstanceId, new Set());
  }
  window._initializedEffectComponentInstances.get(componentInstanceId).add(effectId);
};


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

const DEFAULT_KEY* {.used.} = "page"
var pageComponent* {.used, threadvar.}: Option[proc(key: string = ""): HTML]
var pageComponentName* {.used, threadvar.}: string
var lastRender* {.used, threadvar.}: HTML
var lastRenderTime* {.used, threadvar.}: int64

proc getLastRender*(): HTML =
  return lastRender
proc getLastRenderTime*(): int64 =
  return lastRenderTime

proc clearPageComponent*() =
  pageComponent = none(proc(key: string = ""): HTML)
  pageComponentName = ""
proc setPageComponent*(component: proc(key: string = ""): HTML, name: string) =
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




# proc stateInitEnabled*(componentInstanceId: string): bool =
#   when defined(js):
#     {.emit: "return !window.isComponentInstanceStateInitialized(`componentInstanceId`);"}
#   else:
#     # TODO: ?
#     return true

proc eventInitialized(componentInstanceId: string, effectId: string): bool =
  when defined(js):
    {.emit: "return window.isComponentInstanceEffectInitialized(`componentInstanceId`, `effectId`);".}
  else:
    # TODO: ?
    return true
proc setEventInitialized(componentInstanceId: string, effectId: string) =
  when defined(js):
    {.emit: "window.setComponentInstanceEffectInitialized(`componentInstanceId`, `effectId`);".}
  else:
    discard




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


type Target* = object
  id*: string


var effectListeners* {.used, threadvar.}:       Table[string, Table[string, seq[(EventTarget, string, proc(ev: Event))]]]
# var targetListeners* {.used, threadvar.}: Table[string, Table[string, Table[string, seq[(Target, proc(ev: Event))]]]]
# var targetListenersCreated* {.used, threadvar.}: Table[string, Table[string, seq[string]]]
var targetEffectListeners* {.used, threadvar.}: Table[string, Table[string, Table[string, seq[(Target, proc(ev: Event))]]]]
var registeredTargetEvents* {.used, threadvar.}: seq[string]
proc initEffectListeners() =
  effectListeners = initTable[string, Table[string, seq[(EventTarget, string, proc(ev: Event))]]]()
  
  registeredTargetEvents = @[]
  targetEffectListeners = initTable[string, Table[string, Table[string, seq[(Target, proc(ev: Event))]]]]()

  # targetListeners = initTable[string, Table[string, Table[string, seq[(Target, proc(ev: Event))]]]]()
  # targetListenersCreated = initTable[string, Table[string, seq[string]]]()
initEffectListeners()

var intervals* {.used, threadvar.}: Table[string, Table[string, seq[Interval]]]
var timeouts*  {.used, threadvar.}: Table[string, Table[string, seq[TimeOut]]]
proc initIntervals() =
  intervals = initTable[string, Table[string, seq[Interval]]]()
proc initTimeouts() =
  timeouts = initTable[string, Table[string, seq[TimeOut]]]()
initIntervals()
initTimeouts()

# var targetIds* {.used, threadvar.}: Table[string, string]
# var targets* {.used, threadvar.}: Table[string, Element]
# proc initTargets*() =
#   targets = initTable[string, Element]()
#   targetIds = initTable[string, string]()
# initTargets()
# proc useTarget*(componentInstanceId: string, targetId: string): Target =
#   # only on initialization
  
#   # TODO:  SSR  ID generated vs client ID will differ
#   if eventInitEnabled(componentInstanceId):
#     if targetIds.hasKey(componentInstanceId & "-" & targetId):
#       # echo "Using cached target ID for: ", componentInstanceId, "-", targetId & " -> ", targetIds[componentInstanceId & "-" & targetId]
#       result.id = targetIds[componentInstanceId & "-" & targetId]
#     else:
#       result.id = $fastHash(componentInstanceId & "-" & targetId)
#       echo "Creating new target ID for: ", componentInstanceId, "-", targetId & " -> ", result.id
#       targetIds[componentInstanceId & "-" & targetId] = result.id
#   else:
#     if not targetIds.hasKey(componentInstanceId & "-" & targetId):
#       raise newException(ValueError, "Target not found, useTarget not called during initialization... this should never happen.")
#     result.id = targetIds[componentInstanceId & "-" & targetId]
#     # raise newException(ValueError, "useTarget called but we are not in initialization mode")

proc value*(target: Target): Element =
  let el = document.getElementById(target.id)
  if el == nil:
    raise newException(ValueError, "Target not found: " & target.id)
  return el
converter toElement*(target: Target): Element =
  return target.value()
converter toEventTarget*(target: Target): EventTarget =
  return cast[EventTarget](target.value())
converter toNode*(target: Target): Node =
  return cast[Node](target.value())
converter toString*(target: Target): string =
  return target.id
proc `$`*(target: Target): string =
  return target.id
proc selector*(target: Target): string =
  return "[id='" & target.id & "']"
proc toSelector*(target: Target): string =
  return target.selector()



proc setAttribute*(node: var HTMLNode, name: string, value: string) =
  if node.attributes.isNil:
    node.attributes = new(Table[string, string])
  node.attributes[name] = value
proc setTarget*(node: var HTMLNode, target: Target) =
  node.setAttribute("id", $target)



when defined(js):
  proc setInterval*(componentId: string, effectId: string, action: proc(), ms: int): Interval =
    if not intervals.hasKey(componentId):
      intervals[componentId] = initTable[string, seq[Interval]]()
    if not intervals[componentId].hasKey(effectId):
      intervals[componentId][effectId] = @[]
    
    let interval = dom.setInterval(action, ms)
    intervals[componentId][effectId].add(interval)
    return interval
  proc setTimeout*(componentId: string, effectId: string, action: proc(), ms: int): TimeOut =
    if not timeouts.hasKey(componentId):
      timeouts[componentId] = initTable[string, seq[TimeOut]]()
    if not timeouts[componentId].hasKey(effectId):
      timeouts[componentId][effectId] = @[]
    
    let timeout = dom.setTimeout(action, ms)
    timeouts[componentId][effectId].add(timeout)
    return timeout
  # proc setInterval*(componentId: string, effectId: string, action: proc(), ms: int) =
  #   discard setInterval(componentId, effectId, action, ms)
  # proc setTimeout*(componentId: string, effectId: string, action: proc(), ms: int) =
  #   discard setTimeout(componentId, effectId, action, ms)
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
  

  const NON_BUBBLE_EVENTS = [
    "mouseenter", "mouseleave",
    "focus", "blur",
    "load", "unload",
    "beforeunload",
    "error",
    "abosrt",
    "loadstart",
    "loadend",
    "progress",
    "invalid",
    "scroll"
  ]

  # Target addEventListener
  proc addEventListener*(componentId: string, effectId: string, target: Target, ev: string, cb: proc(ev: Event)) =
    if NON_BUBBLE_EVENTS.contains(ev.toLowerAscii()):
      raise newException(ValueError, "Cannot add event listener for non-bubbling event: " & ev & "\n\nUse a direct EventTarget instead of a Target object.")
    
    if not targetEffectListeners.hasKey(effectId):
      targetEffectListeners[effectId] = initTable[string, Table[string, seq[(Target, proc(ev: Event))]]]()
    if not targetEffectListeners[effectId].hasKey(componentId):
      targetEffectListeners[effectId][componentId] = initTable[string, seq[(Target, proc(ev: Event))]]()
    if not targetEffectListeners[effectId][componentId].hasKey(ev):
      targetEffectListeners[effectId][componentId][ev] = @[]
    targetEffectListeners[effectId][componentId][ev].add((target, cb))


    let isCreated = registeredTargetEvents.contains(ev)
    if not isCreated:
      # add document listener for this event
      document.addEventListener(ev, proc(event: Event) =
        let node = event.target
        if node == nil:
          raise newException(ValueError, "Event target is null")

        for effectId, componentListeners in targetEffectListeners:
          for componentId, listeners in componentListeners:
            if listeners.hasKey(ev):
              for (target, cb) in listeners[ev]:
                let closestMatch = node.closest("[id='" & target.id & "']")
                if closestMatch != nil:
                  # echo "MATCHED CLOSEST: " & target.id
                  cb(event)
      )
      registeredTargetEvents.add(ev)

else:
  proc addEventListener*(componentId: string, effectId: string, et: EventTarget, ev: string, cb: proc(ev: Event), useCapture: bool = false) = discard
  proc addEventListener*(componentId: string, effectId: string, et: EventTarget, ev: string, cb: proc (ev: Event), options: AddEventListenerOptions) = discard
  proc setInterval*(componentId: string, effectId: string, action: proc(), ms: int): Interval = discard
  proc setTimeout*(componentId: string, effectId: string, action: proc(), ms: int): TimeOut = discard
  # proc setInterval*(componentId: string, effectId: string, action: proc(), ms: int) = discard
  # proc setTimeout*(componentId: string, effectId: string, action: proc(), ms: int)= discard

proc clearEffect(componentId: string, effectId: string) =
  logState "Clearing: " & componentId & " - " & componentId
  # echo "Clearing effect event listeners for: ", componentId, " - ", effectId
  if effectListeners.hasKey(effectId) and effectListeners[effectId].hasKey(componentId):
    for (et, ev, cb) in effectListeners[effectId][componentId]:
      et.removeEventListener(ev, cb)
    effectListeners[effectId].del(componentId)

  if targetEffectListeners.hasKey(effectId) and targetEffectListeners[effectId].hasKey(componentId):
    targetEffectListeners[effectId].del(componentId)

  if intervals.hasKey(componentId) and intervals[componentId].hasKey(effectId):
    for interval in intervals[componentId][effectId]:
      dom.clearInterval(interval)
    intervals[componentId].del(effectId)
  if timeouts.hasKey(componentId) and timeouts[componentId].hasKey(effectId):
    for timeout in timeouts[componentId][effectId]:
      dom.clearTimeout(timeout)
    timeouts[componentId].del(effectId)


proc doCallEffect(componentInstanceId: string, effectId: string, deps: openArray[string]): bool =
  when defined(js):
    if deps.len == 0:
      if not eventInitialized(componentInstanceId, effectId):
        # echo "Event not initialized for component: ", componentInstanceId, " effect: ", effectId
        setEventInitialized(componentInstanceId, effectId)
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
      if eventInitialized(componentInstanceId, effectId):
        setEventInitialized(componentInstanceId, effectId)
        return true
  return false

proc useEffect*(componentInstanceId: string, effectId: string, callback: Procedure[proc()]) =
  # TODO: this needs to happen after render?
  when defined(js):
    clearEffect(componentInstanceId, effectId)
    # callback()
    discard dom.setTimeout(proc() =
      callback()
    , 100) # wait for DOM to render, since the effect will occur before the dom is returned

proc useEffect*(componentInstanceId: string, effectId: string, jsCallback: string) =
  when defined(js):
    {.emit: "window.eval(`jsCallback`)"}
  else:
    discard

proc useEffect*[T](componentInstanceId: string, effectId: string, callback: Procedure[T], deps: openArray[string]) =
  if doCallEffect(componentInstanceId, effectId, deps):
    clearEffect(componentInstanceId, effectId)
    discard dom.setTimeout(proc() =
      callback()
    , 100) # wait for DOM to render, since the effect will occur before the dom is returned


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
  # echo "getState: ", componentInstanceId, " - ", key
  let str = getStrState(componentInstanceId, key)
  # echo "getState: ", componentInstanceId, " - ", key, " -> ", str
  # echo T.repr
  return fromJson(str, T)

proc setState*[T](componentInstanceId: string, key: string, value: T) =
  let jsonString = value.toJson()
  when defined(js):
    {.emit: "window.setState(`componentInstanceId`, `key`, `jsonString`)"}
  else:
    logState("not-js, setState", componentInstanceId, key, value)
    serverSideState[componentInstanceId][key] = jsonString
proc setStore*[T](componentInstanceId: string, key: string, value: T) =
  let jsonString = value.toJson()
  when defined(js):
    {.emit: "window.setStore(`componentInstanceId`, `key`, `jsonString`)"}
  else:
    logState("not-js, setStore", componentInstanceId, key, value)
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

proc useStore*[T](componentInstanceId: string, key: string, value: T): (T, proc(n: T), proc(cb: proc(cur: T): T = nil): void) =
  initState(componentInstanceId, key, value)
  when defined(js):
    return (
      getState[T](componentInstanceId, key),
      proc(n: T) = 
        setStore(componentInstanceId, key, n)
      ,
      proc(cb: proc(cur: T): T = nil) =
        let cur = getState[T](componentInstanceId, key)
        let nn = cb(cur)
        setStore(componentInstanceId, key, nn)
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

  const JS_STATE_LOGIC = """
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

window.initState = function(componentInstanceId, key, value) {
  let stateInitialized = window.isComponentInstanceStateInitialized(componentInstanceId, key);
  if(stateInitialized) {
    window.stateLog('initState unavailable', componentInstanceId, key, value);
  } else {
    window.setComponentInstanceStateInitialized(componentInstanceId, key);
    window.stateLog('initState', componentInstanceId, key, value);
    if (window._state[componentInstanceId] == undefined) {
      window._state[componentInstanceId] = {}
    }
    window._state[componentInstanceId][key] = value;
  }
};

window.getState = function(componentInstanceId, key) {
  window.stateLog('getState', componentInstanceId, key);
  try {
    return window._state[componentInstanceId][key]
  } catch (error) {
    // console.log(error);
    // infinitely throw alert with state not found error
    (async () => {
      while(true) {
        alert('FATAL: State not found: ' + componentInstanceId + ' ' + key);
      }
    })();
    throw new Error('State not found: ' + componentInstanceId + ' ' + key)
  }
};

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
};

window.setStore = function(componentInstanceId, key, value) {
  window.stateLog('setStore', componentInstanceId, key, value);
  let preVal = window._state[componentInstanceId][key]
  window._state[componentInstanceId][key] = value;
};
"""
  {.emit: JS_STATE_LOGIC.}



  proc hasDOM*(): bool =
    {.emit: "return window._dom != undefined".}

  proc hasSSRDOM*(): bool =
    {.emit: "return window._ssrDOM != undefined".}

  proc getSSRDOM*(): string =
    {.emit: "return window._ssrDOM".}

  proc isSSR*(): bool =
    {.emit: "return window._ssr".}
 
  proc getPreviousDOM*(): HTML =
    if not hasDOM() and hasSSRDOM() and isSSR():
      var ssrDOM = getSSRDOM()
      let html = fromJson(ssrDOM, HTML)
      return html

    {.emit: "return window._dom".}

  proc render*(html: HTML, fullRender: bool = false) =
    proc doStartAtBody(html: HTML): bool =
      return html[0].tag notin ["html", "head", "body"]
    let startAtBody = html.doStartAtBody()

    # Define void elements that cannot have children
    const voidElements = ["area", "base", "br", "col", "embed", "hr", "img", 
                        "input", "link", "meta", "source", "track", "wbr"]

    # Helper function to check if a DOM node should be preserved
    proc shouldPreserveNode(domNode: Node): bool =
      if domNode.nodeType == ElementNode:
        let element = cast[Element](domNode)
        # Preserve tags with op='true' attribute
        if element.hasAttribute("op") and element.getAttribute("op") == "true":
          return true
      return false

    # if no previous DOM, or forced full render -> do full render
    if (not hasDOM() and not hasSSRDOM()) or fullRender:
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
        lastRender = html
        lastRenderTime = int64(getTime().toUnixFloat() * 1000)
        {.emit: "window._last_render = Date.now();".}
        {.emit: "window._dom = `html`;".}  # Still update the stored DOM
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

      # Helper to collect preserved nodes before removal
      proc collectPreservedNodes(parent: Node, startIndex: int): seq[Node] =
        var preserved: seq[Node] = @[]
        var count = 0
        for child in parent.childNodes:
          if child.nodeType == ElementNode or child.nodeType == TextNode:
            if count >= startIndex and shouldPreserveNode(child):
              preserved.add(child)
            inc count
        return preserved

      proc check(previousDOM: HTML, html: HTML, parent: Node = nil, depth: int = 0) =
        let indent = repeat("  ", depth)
        # logState(indent & "Checking level with", $previousDOM.len, "old nodes and", $html.len, "new nodes")
        
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
        
        # logState(indent & "DOM has", $domCount, "relevant children")

        # Collect nodes to preserve before any removal operations
        let preservedNodes = if parent == nil:
          if startAtBody:
            collectPreservedNodes(document.body, newCount)
          else:
            collectPreservedNodes(document.documentElement, newCount)
        else:
          collectPreservedNodes(parent, newCount)

        for i in 0..<max(max(oldCount, newCount), domCount):
          # Remove extra nodes from DOM (but preserve special nodes)
          if i >= newCount:
            let nodeEl = if parent == nil:
              if startAtBody: 
                getRelevantChild(document.body, i)
              else: 
                getRelevantChild(document.documentElement, i)
            else: 
              getRelevantChild(parent, i)
            
            if nodeEl != nil and nodeEl.parentNode != nil:
              # Check if this node should be preserved
              if shouldPreserveNode(nodeEl):
                logState(indent & "Preserving node at index", $i, "(script tag or op='true')")
                continue
              else:
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

          # Check if existing node should be preserved (skip replacement)
          if shouldPreserveNode(nodeEl):
            logState(indent & "Preserving existing node at index", $i, "(script tag or op='true')")
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
            # else:
              # logState(indent & "Text content unchanged at index", $i)
          
          # Handle element nodes
          elif newNode.kind == htmlnkElement:
            var attributeChanged = false
            

            # Normalize attribute values - treat null and empty string as equivalent
            proc normalizeAttrValue(value: cstring): string =
              if value == nil or $value == "null" or $value == "":
                return ""
              else:
                return $value
            
            # Diff attributes with detailed logging
            for k, v in newNode.attributes:
              let attrValue = nodeEl.getAttribute(k)
              let currentValue = if attrValue.isNil: "" else: normalizeAttrValue(attrValue)
              let normalizedNewValue = normalizeAttrValue(cstring(v))
              let oldValue = if oldNode.isSome: 
                normalizeAttrValue(cstring(oldNode.get.attributes.getOrDefault(k, "")))
              else: 
                ""
              
              
              proc mergeStyles(currentValue: string, newValue: string): string =
                if currentValue == "":
                  return newValue
                elif newValue == "":
                  return currentValue
                else:
                  # Merge styles by splitting by semicolon, then splitting by name and value- update values or add new ones
                  var currentStyles = currentValue.split(";").mapIt(it.strip())
                  var newStyles = newValue.split(";").mapIt(it.strip())
                  var mergedStyles = initTable[string, string]()
                  for style in currentStyles:
                    if style != "":
                      let parts = style.split(":")
                      if parts.len == 2:
                        let name = parts[0].strip()
                        let value = parts[1].strip()
                        # mergedStyles[parts[0].strip()] = parts[1].strip()
                        
                        # only keep if we are a KEEP_STYLE and the value includes a px
                        const KEEP_STYLES = ["width", "height"]
                        if name in KEEP_STYLES and value.contains("px"):
                          mergedStyles[name] = value
                        else:
                          # logState("Skipping style", name, "with value", value, "because it is not a KEEP_STYLE")
                          continue
                        
                  for style in newStyles:
                    if style != "":
                      let parts = style.split(":")
                      if parts.len == 2:
                        let key = parts[0].strip()
                        let value = parts[1].strip()
                          # Update existing style value
                        mergedStyles[key] = value
                  # Join merged styles back into a string
                  # return mergedStyles.toSeq().mapIt(it[0] & ": " & it[1]).join("; ")
                  var str = ""
                  for key, value in mergedStyles:
                    if str != "":
                      str &= "; "
                    str &= key & ": " & value
                  return str

              if k == "style":
                let mergedStyle = mergeStyles(currentValue, normalizedNewValue)
                if mergedStyle != currentValue:
                  logState(indent & "Setting style attribute at index", $i, "to", mergedStyle, "(current DOM value:", currentValue, ", old virtual value:", oldValue, ")")
                  nodeEl.setAttribute(k, mergedStyle)
                  
              else:
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
                # else:
                  # logState(indent & "Attribute", k, "unchanged at index", $i, "(normalized value:", normalizedNewValue, ")")
              
              
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

        # Re-append preserved nodes that were collected earlier
        for preservedNode in preservedNodes:
          if preservedNode.parentNode == nil:  # Only re-append if it was actually removed
            logState(indent & "Re-appending preserved node")
            if parent == nil:
              if startAtBody:
                document.body.appendChild(preservedNode)
              else:
                document.documentElement.appendChild(preservedNode)
            else:
              parent.appendChild(preservedNode)

      # Start the diffing process
      check(previousDOM, html)


    lastRender = html
    lastRenderTime = int64(getTime().toUnixFloat() * 1000)
    {.emit: "window._last_render = Date.now();".}
    {.emit: "window._dom = `html`"}
    # {.emit: "window._state_init_enabled = false"}
    # {.emit: "window._event_init_enabled = false"}

  proc renderAll*() =
    logState("Rendering page '" & pageComponentName & "'")
    # log "page: " & pageComponentName

    # if not isSSR:
    #   {.emit: "window._state_init_enabled = true"}
    # {.emit: "window._event_init_enabled = true"}
    {.emit: "window.removeAllEventListeners();"}
    {.emit: "window._initializedStateComponentInstances = [];".}
    {.emit: "window._initializedEffectComponentInstances = [];".}
    render(
      (pageComponent.get())(key = DEFAULT_KEY)
    )
    # {.emit: "window._state_init_enabled = false"}
    # {.emit: "window._event_init_enabled = false"}

  const ALWAYS_FORCE_FULL_RENDER = false

  import times
  proc onStateUpdated*(componentInstanceId: string) =
    logState "State updated for: ", componentInstanceId, "\nAttempting render..."
    # TODO: contemplate grabbing `web thing` for componentInstanceId and rendering from there

    # {.emit: "window.removeAllEventListeners()"} # TODO: disabled for useEffect event listener overlap
    # {.emit: "window.removeAllDOMEventListeners()"}
    let startTime = (epochTime() * 1000).int64
    let html = (pageComponent.get())(key = DEFAULT_KEY)
    let elapsedTime = ((epochTime() * 1000).int64) - startTime
    logState "Render took: " & $elapsedTime & "ms"

    let renderStartTime = (epochTime() * 1000).int64
    render(
      html,
      ALWAYS_FORCE_FULL_RENDER
    )
    let renderElapsedTime = ((epochTime() * 1000).int64) - renderStartTime
    logState "Render function took: " & $renderElapsedTime & "ms"

  document.addEventListener("DOMContentLoaded", proc(ev: Event) =

    # TODO: this is broken, we always need a render on the client side

    if isSSR():
      # state is injected by server, but effects/events are not intialized/setup so we must render
      {.emit: "window.removeAllEventListeners();"}
      discard (pageComponent.get())(key = DEFAULT_KEY)
    else:
      renderAll()
  )

  attachToWindow "renderAll", renderAll
  attachToWindow "onStateUpdated", onStateUpdated

