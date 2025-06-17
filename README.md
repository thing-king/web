# web

Macro-based HTML & CSS generation system for Nim — powering the **Thing** framework.

---

## Overview

`web` provides a macro-driven approach to building full web UIs directly in Nim using declarative, type-safe HTML and CSS generation. It integrates directly into the [Thing framework](https://github.com/thing-king/thing).

---

## Key Principles

* Component-driven architecture
* Inline styles preferred — automatically compiled to isolated CSS classes at build time
* Avoids decoupled global CSS — style remains directly tied to component state
* Class-based styling supported but discouraged
* Designed to integrate directly into Thing’s reactive full-stack system
* Fully integrated state management layer (provided by the full Thing framework)

---

## State Management (Full Framework)

In the full Thing framework, `web` integrates with a React-inspired state system, including:

* `useState` style state hooks
* `useEffect` lifecycle hooks
* Full diffing-based DOM reconciliation
* Deterministic state propagation identical to React semantics
* Built entirely within Nim and fully compile-time validated

This allows building fully reactive, state-driven web applications with declarative Nim code.

---

## Dependencies

* [css](https://github.com/thing-king/css): Compile-time and runtime CSS validation
* [html](https://github.com/thing-king/html): MDN-typed HTML elements

---

## Core Usage

### HTML Generation

```nim
import web

let someText = "Dynamic content"

let html = web:
  p "Simple text"
  
  p:
    "Multiple lines"
    someText
    
  p:
    "With attributes"
    id "main-paragraph"
    class "highlight"
```

---

### Styling

By default, inline styles are compiled into generated CSS classes automatically:

```nim
web:
  p "Validated styling":
    style:
      color: red
      fontSize: 16.px
      margin: {8.px, 16.px}
```

#### Dynamic values

```nim
var textDecorationValue = "underline"

web:
  p "Dynamic style":
    style:
      textDecoration: `textDecorationValue`
```

#### External style objects

```nim
var styles = newStyles()
styles.color = "red"
styles.marginBlock = {1.px, 2.px}

web:
  box:
    style styles
```

---

### Selectors

```nim
web:
  p "Interactive element":
    class textElement
    style:
      !textElement:
        color: blue
      !textElement[hover]:
        color: darkBlue
      [root]:
        backgroundColor: white
```

* `!` = class selector
* `[state]` = pseudo-classes

---

## Components

### Basic Components

```nim
proc Card(title: string, content: string): HTML =
  return web:
    box:
      class "card"
      h2: title
      p: content

web:
  Card:
    title "Hello"
    content "This is a card"
```

### Components with Children

```nim
proc Container(children: HTML): HTML =
  return web:
    box:
      class "container"
      children

web:
  Container:
    children:
      h1 "Title"
      p "Body"
```

### Attribute & Style Passthrough

```nim
web:
  Card:
    title "Hello"
    `id` "custom-card"
    `style`:
      backgroundColor: blue
```

### Component Name Conflicts

```nim
proc p(content: string): HTML =
  return web:
    box: content

web:
  `p`:
    content "Custom paragraph"
```

---

## Types

```nim
type HTMLNodeKind* = enum
  htmlnkElement
  htmlnkText

type HTMLNode* = object
  elementId*: string
  case kind*: HTMLNodeKind
  of htmlnkElement:
    tag*: string
    attributes*: Table[string, string]
    children*: seq[HTMLNode]
  of htmlnkText:
    text*: string

type HTML* = seq[HTMLNode]
```

---

## Framework Integration

The `web` package is built specifically for use inside the [Thing framework](https://github.com/thing-king/thing).

* Style and component state remain tightly coupled.
* Inline styles automatically generate scoped CSS classes — no manual class management required.
* Global class usage is supported for external libraries but generally discouraged inside Thing projects.
* Fully reactive state layer, lifecycle management, and DOM diffing handled by Thing core.

---

> `web` is a first-class HTML/CSS generation layer fully integrated into Thing’s self-hosted full-stack system.
