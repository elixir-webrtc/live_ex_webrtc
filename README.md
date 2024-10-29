# LiveExWebRTC

[![Hex.pm](https://img.shields.io/hexpm/v/live_ex_webrtc.svg)](https://hex.pm/packages/live_ex_webrtc)
[![API Docs](https://img.shields.io/badge/api-docs-yellow.svg?style=flat)](https://hexdocs.pm/live_ex_webrtc)

Phoenix Live Components for Elixir WebRTC.

## Installation

In your `mix.exs`:

```elixir
def deps do
  [
    {:live_ex_webrtc, "~> 0.2.1"}
  ]
end
```

In your `tailwind.config.js`

```js
module.exports = {
  content: [
    "../deps/live_ex_webrtc/**/*.*ex" // ADD THIS LINE
  ]
}
```

## Usage

`LiveExWebRTC` comes with two `Phoenix.LiveView`s:
* `LiveExWebRTC.Publisher` - sends audio and video via WebRTC from a web browser to a Phoenix app (browser publishes)
* `LiveExWebRTC.Player` - sends audio and video via WebRTC from a Phoenix app to a web browser and plays it in the HTMLVideoElement (browser subscribes)

See module docs for more.

## Local development

For local development:
* include `live_ex_webrtc` in your `mix.exs` via `path` 
* modify `NODE_PATH` env variable in your esbuild configuration, which is located in `config.exs` - this will allow for importing javascript hooks from `live_ex_webrtc`.

  For example:

  ```elixir
  config :esbuild,
    # ...
    default: [
      # ...
      env: %{
        "NODE_PATH" => "#{Path.expand("../deps", __DIR__)}:/path/to/parent/dir/of/live_ex_webrtc"
      }
    ]
  ```

* modify `content` in `tailwind.config.js` - this will compile tailwind classes used in live components.
  
  For example:

  ```js
  module.exports = {
    content: [
      // ...
      "../deps/**/*.ex"
    ]
  }
  ```

> #### Important {: .info}
> Separate paths with `:` on MacOS/Linux and with `;` on Windows.

> #### Important {: .info}
> Specify path to live_ex_webrtc's parent directory.
