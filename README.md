# web
Macro-based HTML generation library for Nim with integrated CSS support.

## Installation

```bash
nimble install web
```

## Dependencies

- [css](https://github.com/thing-king/css): CSS DSL, compile and runtime MDN-backed validation
- [html](https://github.com/thing-king/html): MDN-typed HTML elements

## Core Features

- Single `web` macro for HTML generation
- Integrated `style` macro with CSS validation
- Component-based architecture
- CSS property validation at both compile-time and runtime

## Basic HTML Generation

```nim
import web

let someText = "Dynamic content"

let html = web:
  p "Simple text"
  
  p:
    "Multiple lines"
    someText # Variable interpolation
    
  p:
    "With attributes"
    id "main-paragraph"
    class "highlight"
```

## Styling with Validation

The `style` macro leverages the `css` package for property validation:

```nim
var textDecorationValue = "underline"

web:
  p "Validated styling":
    style:
      color: red             # Compile-time validation
      fontSize: 16.px        # Units require period
      margin: {8.px, 16.px}  # Multiple values use {}
      padding: "10px 5px"    # Strings work too
    
      # Inject variable
      textDecoration: `textDecorationValue`

      # CSS variables
      --theme-color: blue
      backgroundColor: cvar(--theme-color)  # Use cvar instead of var
```

Or, via `css` create a `newStyles()` object and pass that as the style:
```nim

var styles = newStyles()
styles.marginInline = {1.px, 2.px}  # compile-time validated
styles.color  = "red"

var dynamicValue = "5px"
styles.paddingRight = dynamicValue
styles.marginBlock  = {1.px, `dynamicValue`}

web:
  box:
    style styles
    style:
      color: red # multiple style tags work
```

## Selectors and Advanced Styling

```nim
web:
  p "Interactive element":
    class textElement
    style:
      # Selectors create indepdent <style> tags
      !textElement:  # Use ! instead of . for class selectors
        color: blue
      
      !textElement[hover]:  # Pseudo-classes
        color: darkBlue
      
      [root]:  # Root selector
        backgroundColor: white
    
      # Property assignments apply to parent
      "custom-property": "value"  # String property names supported
```

## Components

Components are regular Nim procedures that return HTML:

```nim
proc Card(title: string, content: string): HTML =
  return web:
    box:  # Use box instead of div (Nim keyword)
      class "card"
      h2: title
      p: content

# Usage
let html = web:
  Card:
    title "Hello"
    content "This is a card component"
```

## Components with Children

```nim
proc Container(children: HTML): HTML =
  return web:
    box:
      class "container"
      children

# Usage
let html = web:
  Container:
    children:
      h1 "Website Title"
      p "Welcome to my site"
```

## Attribute and Style Pass-through
Passthrough an attribute to apply to the top-level of a component

```nim
let html = web:
  Card:
    title "Hello"
    `id` "custom-card"  # Passthrough attribute
    `style`:            # Passthrough styling
      backgroundColor: blue
```

## Component Name Conflicts

```nim
proc p(content: string): HTML =  # Component with same name as HTML tag
  return web:
    box: content

# Use backticks to specify the component
let html = web:
  `p`:  # Use component, not HTML tag
    content "Custom paragraph"
```

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
    attributes*: Table[string, string] = initTable[string, string]()
    children*: seq[HTMLNode] = @[]
  of htmlnkText:
    text*: string

type HTML* = seq[HTMLNode]
```