# LiveExWebrtc

Phoenix Live Components for Elixir WebRTC.

## Installation

```elixir
def deps do
  [
    {:live_ex_webrtc, "~> 0.1.0"}
  ]
end
```

## Usage

1. Add LiveExWebRTCPlayer hook to the list of your Phoenix Live View hooks:

```js
import { LiveExWebRTCPlayer } from 'live_ex_webrtc';
let Hooks = {};
Hooks.LiveExWebRTCPlayer = LiveExWebRTCPlayer;
let liveSocket = new LiveSocket('live', Socket, { hooks: Hooks} );
```

2. Use LiveExWebRTC.Player component in your LiveView:

```ex
defmodule MyLiveView do
  use Phoenix.LiveView

  alias ExWebRTC.RTPCodecParameters

  @video_codecs [
    %RTPCodecParameters{
      payload_type: 96,
      mime_type: "video/VP8",
      clock_rate: 90_000
    }
  ]

  def mount(_params, _session, socket) do
    socket = assign(socket, video_codecs: @video_codecs)
    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <.live_component module={LiveExWebRTC.Player} id="player" video_codecs={@video_codecs} />
    """
  end
end
```
