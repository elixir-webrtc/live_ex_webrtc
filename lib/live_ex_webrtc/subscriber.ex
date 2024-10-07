defmodule LiveExWebRTC.Subscriber do
  @moduledoc """
  `Phoenix.LiveComponent` for sending audio and video via WebRTC from a Phoenix app to a browser (browser subscribes).

  It will render a single HTMLVideoElement.

  Once rendered, your `Phoenix.LiveView` will receive `t:init_msg/0` and can start
  sending RTP packets to the browser using `ExWebRTC.PeerConnection.send_rtp/4`, where
  there first argument is a pid received in `t:init_msg/0`. For example:

  ```elixir
  ExWebRTC.PeerConnection.send_rtp(init_msg[:pc], init_msg[:audio_track_id], audio_packet)
  ExWebRTC.PeerConnection.send_rtp(init_msg[:pc], init_msg[:video_track_id], video_packet)
  ```

  Subscriber always negotiates a single audio and video track.

  ## Assigns

  * `ice_servers` - a list of `t:ExWebRTC.PeerConnection.Configuration.ice_server/0`,
  * `ice_ip_filter` - `t:ExICE.ICEAgent.ip_filter/0`,
  * `ice_port_range` - `t:Enumerable.t(non_neg_integer())/1`,
  * `audio_codecs` - a list of `t:ExWebRTC.RTPCodecParameters.t/0`,
  * `video_codecs` - a list of `t:ExWebRTC.RTPCodecParameters.t/0`,
  * `gen_server_name` - `t:GenServer.name/0`
  * `class` - list of CSS/Tailwind classes that will be applied to the HTMLVideoPlayer. Defaults to "".

  ## JavaScript Hook

  Subscriber live component requires JavaScript hook to be registered under `Subscriber` name.
  The hook can be created using `createSubscriberHook` function.
  For example:

  ```javascript
  import { createSubscriberHook } from "live_ex_webrtc";
  let Hooks = {};
  const iceServers = [{ urls: "stun:stun.l.google.com:19302" }];
  Hooks.Subscriber = createSubscriberHook(iceServers);
  let liveSocket = new LiveSocket("/live", Socket, {
    // ...
    hooks: Hooks
  });
  ```

  ## Examples

  ```elixir
  <.live_component
    module={LiveExWebRTC.Subscriber}
    id="subscriber"
    ice_servers={[%{urls: "stun:stun.l.google.com:19302"}]}
  />
  ```
  """
  use Phoenix.LiveComponent

  alias ExWebRTC.{ICECandidate, MediaStreamTrack, PeerConnection, SessionDescription}

  @typedoc """
  Message sent to the `Phoenix.LiveView` after component's initialization.

  * `pc` - `ExWebRTC.PeerConnection`'s pid spawned by this live component.
  It can be used to send RTP packets to the browser using `ExWebRTC.PeerConnection.send_rtp/4`.
  * `audio_track_id` - id of audio track
  * `video_track_id` - id of video track
  """
  @type init_msg() ::
          {:live_ex_webrtc,
           %{
             pc: pid(),
             audio_track_id: String.t(),
             video_track_id: String.t()
           }}

  @impl true
  def render(assigns) do
    assigns = assign_new(assigns, :class, fn -> "" end)

    ~H"""
    <video id={@id} phx-hook="Subscriber" class={@class} controls autoplay muted></video>
    """
  end

  @impl true
  def handle_event(_event, _unsigned_params, %{assigns: %{pc: nil}} = socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("offer", unsigned_params, socket) do
    offer = SessionDescription.from_json(unsigned_params)
    {:ok, pc} = spawn_peer_connection(socket)

    :ok = PeerConnection.set_remote_description(pc, offer)

    stream_id = MediaStreamTrack.generate_stream_id()
    audio_track = MediaStreamTrack.new(:audio, [stream_id])
    video_track = MediaStreamTrack.new(:video, [stream_id])
    {:ok, _sender} = PeerConnection.add_track(pc, audio_track)
    {:ok, _sender} = PeerConnection.add_track(pc, video_track)

    info = %{pc: pc, audio_track_id: audio_track.id, video_track_id: video_track.id}
    send(self(), {:live_ex_webrtc, info})

    {:ok, answer} = PeerConnection.create_answer(pc)
    :ok = PeerConnection.set_local_description(pc, answer)
    :ok = gather_candidates(pc)
    answer = PeerConnection.get_local_description(pc)

    socket = assign(socket, :pc, pc)
    socket = push_event(socket, "answer-#{socket.assigns.id}", SessionDescription.to_json(answer))

    {:noreply, socket}
  end

  @impl true
  def handle_event("ice", "null", socket) do
    :ok = PeerConnection.add_ice_candidate(socket.assigns.pc, %ICECandidate{candidate: ""})
    {:noreply, socket}
  end

  @impl true
  def handle_event("ice", unsigned_params, socket) do
    cand =
      unsigned_params
      |> Jason.decode!()
      |> ExWebRTC.ICECandidate.from_json()

    :ok = PeerConnection.add_ice_candidate(socket.assigns.pc, cand)

    {:noreply, socket}
  end

  defp spawn_peer_connection(socket) do
    pc_opts =
      [
        ice_servers: socket.assigns[:ice_servers],
        ice_ip_filter: socket.assigns[:ice_ip_filter],
        ice_port_range: socket.assigns[:ice_port_range],
        audio_codecs: socket.assigns[:audio_codecs],
        video_codecs: socket.assigns[:video_codecs]
      ]
      |> Enum.reject(fn {_k, v} -> v == nil end)

    gen_server_opts =
      [name: socket.assigns[:gen_server_name]]
      |> Enum.reject(fn {_k, v} -> v == nil end)

    PeerConnection.start_link(pc_opts, gen_server_opts)
  end

  defp gather_candidates(pc) do
    # we either wait for all of the candidates
    # or whatever we were able to gather in one second
    receive do
      {:ex_webrtc, ^pc, {:ice_gathering_state_change, :complete}} -> :ok
    after
      1000 -> :ok
    end
  end
end
