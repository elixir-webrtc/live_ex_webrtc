defmodule LiveExWebRTC.Publisher do
  @moduledoc ~S'''
  Component for sending audio and video via WebRTC from a browser to a Phoenix app (browser publishes).

  It:
  * renders:
    * audio and video device selects
    * audio and video stream configs
    * stream recording toggle (with recordings enabled)
    * stream preview
    * transmission stats
  * on clicking "Start Streaming", creates WebRTC PeerConnection both on the client and server side
  * connects those two peer connections negotiatiing a single audio and video track
  * sends audio and video from selected devices to the live view process
  * publishes received audio and video packets to the configured PubSub
  * can optionally use the [ExWebRTC Recorder](https://github.com/elixir-webrtc/ex_webrtc_recorder) to record the stream

  When `LiveExWebRTC.Player` is used, audio and video packets are delivered automatically,
  assuming both components are configured with the same PubSub.

  If `LiveExWebRTC.Player` is not used, you should use following topics and messages:
  * `streams:audio:#{publisher_id}:#{audio_track_id}` - for receiving audio packets
  * `streams:video:#{publisher_id}:#{video_track_id}:#{layer}` - for receiving video packets.
  The message is in form of `{:live_ex_webrtc, :video, "l" | "m" | "h", ExRTP.Packet.t()}` or
  `{:live_ex_webrtc, :audio, ExRTP.Packet.t()}`. Packets for non-simulcast video tracks are always
  sent with "h" identifier.
  * `streams:info:#{publisher.id}"` - for receiving information about publisher tracks and their layers.
  The message is in form of: `{:live_ex_webrtc, :info, audio_track :: ExWebRTC.MediaStreamTrack.t(), video_track :: ExWebRTC.MediaStreamTrack.t()}`.
  * `publishers:#{publisher_id}` for sending keyframe request.
  The message must be in form of `{:live_ex_webrtc, :keyframe_req, "l" | "m" | "h"}`
  E.g.
  ```elixir
  PubSub.broadcast(LiveTwitch.PubSub, "publishers:my_publisher", {:live_ex_webrtc, :keyframe_req, "h"})
  ```

  ## JavaScript Hook

  Publisher live view requires JavaScript hook to be registered under `Publisher` name.
  The hook can be created using `createPublisherHook` function.
  For example:

  ```javascript
  import { createPublisherHook } from "live_ex_webrtc";
  let Hooks = {};
  const iceServers = [{ urls: "stun:stun.l.google.com:19302" }];
  Hooks.Publisher = createPublisherHook(iceServers);
  let liveSocket = new LiveSocket("/live", Socket, {
    // ...
    hooks: Hooks
  });
  ```

  ## Simulcast

  Simulcast requires video codecs to be H264 (packetization mode 1) and/or VP8. E.g.

  ```elixir
  video_codecs = [
    %RTPCodecParameters{
      payload_type: 98,
      mime_type: "video/H264",
      clock_rate: 90_000,
      sdp_fmtp_line: %FMTP{
        pt: 98,
        level_asymmetry_allowed: true,
        packetization_mode: 1,
        profile_level_id: 0x42E01F
      }
    },
    %RTPCodecParameters{
      payload_type: 96,
      mime_type: "video/VP8",
      clock_rate: 90_000
    }
  ]
  ```

  ## Examples

  ```elixir
  defmodule LiveTwitchWeb.StreamerLive do
    use LiveTwitchWeb, :live_view

    alias LiveExWebRTC.Publisher

    @impl true
    def render(assigns) do
    ~H"""
    <Publisher.live_render socket={@socket} publisher={@publisher} />
    """
    end

    @impl true
    def mount(_params, _session, socket) do
      socket = Publisher.attach(socket, id: "publisher", pubsub: LiveTwitch.PubSub)
      {:ok, socket}
    end
  end
  ```
  '''
  use Phoenix.LiveView

  require Logger

  import LiveExWebRTC.CoreComponents

  alias ExWebRTC.RTPCodecParameters
  alias LiveExWebRTC.Publisher
  alias ExWebRTC.{ICECandidate, PeerConnection, Recorder, SessionDescription}
  alias Phoenix.PubSub

  @typedoc """
  Called when WebRTC has connected.
  """
  @type on_connected :: (publisher_id :: String.t() -> any())

  @typedoc """
  Called when WebRTC has disconnected.
  """
  @type on_disconnected :: (publisher_id :: String.t() -> any())

  @typedoc """
  Called when recorder finishes stream recording.

  For exact meaning of the second argument, refer to `t:ExWebRTC.Recorder.end_tracks_ok_result/0`.
  """
  @type on_recording_finished :: (publisher_id :: String.t(), Recorder.end_tracks_ok_result() ->
                                    any())

  @type on_packet ::
          (publisher_id :: String.t(),
           packet_type :: :audio | :video,
           layer :: nil | String.t(),
           packet :: ExRTP.Packet.t(),
           socket :: Phoenix.LiveView.Socket.t() ->
             packet :: ExRTP.Packet.t())

  @type t :: struct()

  defstruct id: nil,
            pc: nil,
            streaming?: false,
            simulcast_supported?: nil,
            # record checkbox status
            record?: false,
            # whether recorings are allowed or not
            recordings?: true,
            # recorder instance
            recorder: nil,
            recorder_opts: [],
            audio_track: nil,
            video_track: nil,
            on_packet: nil,
            on_connected: nil,
            on_disconnected: nil,
            on_recording_finished: nil,
            pubsub: nil,
            ice_servers: nil,
            ice_ip_filter: nil,
            ice_port_range: nil,
            audio_codecs: nil,
            video_codecs: nil,
            pc_genserver_opts: nil

  attr(:socket, Phoenix.LiveView.Socket, required: true, doc: "Parent live view socket")

  attr(:publisher, __MODULE__,
    required: true,
    doc: """
    Publisher struct. It is used to pass publisher id to the newly created live view via live view session.
    This data is then used to do a handshake between parent live view and child live view during which child live
    view receives the whole Publisher struct.
    """
  )

  @doc """
  Helper function for rendering Publisher live view.
  """
  def live_render(assigns) do
    ~H"""
    {live_render(@socket, __MODULE__,
      id: "#{@publisher.id}-lv",
      session: %{"publisher_id" => @publisher.id}
    )}
    """
  end

  @doc """
  Attaches required hooks and creates `t:t/0` struct.

  Created struct is saved in socket's assigns and has to be passed to `LiveExWebRTC.Publisher.live_render/1`.

  Options:
  * `id` - publisher id. This is typically your user id (if there is users database).
  It is used to identify live view and generated HTML elements.
  * `pubsub` - a pubsub that publisher live view will use for broadcasting audio and video packets received from a browser. See module doc for more info.
  * `recordings?` - whether to allow for recordings or not. Defaults to true.
    See module doc and `t:on_disconnected/0` for more info.
  * `recorder_opts` - a list of options that will be passed to the recorder. In particular, they can contain S3 config where recordings will be uploaded. See `t:ExWebRTC.Recorder.option/0` for more.
  * `on_connected` - callback called when the underlying peer connection changes its state to the `:connected`. See `t:on_connected/0`.
  * `on_disconnected` - callback called when the underlying peer connection process terminates. See `t:on_disconnected/0`.
  * `on_recording_finished` - callback called when the stream recording has finised. See `t:on_recording_finished/0`.
  * `on_packet` - callback called for each audio and video RTP packet. Can be used to modify the packet before publishing it on a pubsub. See `t:on_packet/0`.
  * `ice_servers` - a list of `t:ExWebRTC.PeerConnection.Configuration.ice_server/0`,
  * `ice_ip_filter` - `t:ExICE.ICEAgent.ip_filter/0`,
  * `ice_port_range` - `t:Enumerable.t(non_neg_integer())/1`,
  * `audio_codecs` - a list of `t:ExWebRTC.RTPCodecParameters.t/0`,
  * `video_codecs` - a list of `t:ExWebRTC.RTPCodecParameters.t/0`,
  * `pc_genserver_opts` - `t:GenServer.options/0` for the underlying `ExWebRTC.PeerConnection` process.
  """
  @spec attach(Phoenix.LiveView.Socket.t(), Keyword.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket, opts) do
    opts =
      Keyword.validate!(opts, [
        :id,
        :name,
        :pubsub,
        :recordings?,
        :recorder_opts,
        :on_packet,
        :on_connected,
        :on_disconnected,
        :on_recording_finished,
        :ice_servers,
        :ice_ip_filter,
        :ice_port_range,
        :audio_codecs,
        :video_codecs,
        :pc_genserver_opts
      ])

    publisher = %Publisher{
      id: Keyword.fetch!(opts, :id),
      pubsub: Keyword.fetch!(opts, :pubsub),
      recordings?: Keyword.get(opts, :recordings?, true),
      recorder_opts: Keyword.get(opts, :recorder_opts, []),
      on_packet: Keyword.get(opts, :on_packet),
      on_connected: Keyword.get(opts, :on_connected),
      on_disconnected: Keyword.get(opts, :on_disconnected),
      on_recording_finished: Keyword.get(opts, :on_recording_finished),
      ice_servers: Keyword.get(opts, :ice_servers, [%{urls: "stun:stun.l.google.com:19302"}]),
      ice_ip_filter: Keyword.get(opts, :ice_ip_filter),
      ice_port_range: Keyword.get(opts, :ice_port_range),
      audio_codecs: Keyword.get(opts, :audio_codecs),
      video_codecs: Keyword.get(opts, :video_codecs),
      pc_genserver_opts: Keyword.get(opts, :pc_genserver_opts, [])
    }

    # Check the "Record stream?" checkbox by default if recordings are allowed
    record? = publisher.recordings? == true

    socket
    |> assign(publisher: %Publisher{publisher | record?: record?})
    |> attach_hook(:handshake, :handle_info, &handshake/2)
  end

  defp handshake({__MODULE__, {:connected, ref, pid, _meta}}, socket) do
    send(pid, {ref, socket.assigns.publisher})
    {:halt, socket}
  end

  defp handshake(_msg, socket) do
    {:cont, socket}
  end

  ## CALLBACKS

  @impl true
  def render(%{publisher: nil} = assigns) do
    ~H"""
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@publisher.id} phx-hook="Publisher" class="h-full w-full flex flex-col gap-2">
      <div class="flex-grow w-full h-[0px] flex flex-col gap-4">
        <video
          id="lex-preview-player"
          class="rounded-lg bg-black h-full object-contain"
          autoplay
          controls
          muted
        >
        </video>
      </div>
      <div class="flex items-center justify-between">
        <div
          id="lex-audio-devices-wrapper"
          class="flex gap-2 items-center relative"
          phx-update="ignore"
        >
          <label for="lex-audio-devices" class="absolute left-3 top-[5px] pointer-events-none">
            <.icon name="hero-microphone" class="w-4 h-4" />
          </label>
          <select
            id="lex-audio-devices"
            class="pl-9 rounded-lg text-sm border-indigo-200 disabled:text-gray-400 disabled:border-gray-400 focus:border-indigo-900 focus:outline-none focus:ring-0"
          >
          </select>
        </div>
        <div
          id="lex-video-devices-wrapper"
          class="flex gap-2 items-center relative"
          phx-update="ignore"
        >
          <label for="lex-video-devices" class="absolute left-3 top-[5px] pointer-events-none">
            <.icon name="hero-video-camera" class="w-4 h-4" />
          </label>
          <select
            id="lex-video-devices"
            class="pl-9 rounded-lg text-sm border-indigo-200 disabled:text-gray-400 disabled:border-gray-400 focus:border-indigo-900 focus:outline-none focus:ring-0"
          >
          </select>
        </div>
      </div>
      <div class="flex items-stretch gap-4">
        <button
          class="border border-indigo-700 px-4 py-2 rounded-lg text-indigo-800 flex items-center justify-center gap-2"
          phx-click={show_modal("settings-modal")}
        >
          <.icon name="hero-cog-6-tooth" class="w-4 h-4" />
        </button>
        <button
          :if={!@publisher.streaming?}
          id="lex-button"
          class="bg-indigo-800 flex-1 flex items-center justify-center gap-2 px-4 py-2 text-white rounded-lg"
          phx-click="start-streaming"
        >
          <.icon name="hero-play" class="w-4 h-4" /> Start streaming
        </button>
        <button
          :if={@publisher.streaming?}
          id="lex-button"
          class="bg-rose-500 flex-1 flex items-center justify-center gap-2 px-4 py-2 text-white rounded-lg"
          phx-click="stop-streaming"
        >
          <.icon name="hero-stop" class="w-4 h-4" /> Stop streaming
        </button>
        <div class="p-1 flex items-center hidden">
          <div id="lex-status" class="w-3 h-3 rounded-full bg-red-500"></div>
        </div>
        <form class="flex flex-col gap-1 items-center">
          <label class="relative inline-flex items-center cursor-pointer">
            <input
              type="checkbox"
              class="sr-only peer appearance-none"
              id="lex-record-stream"
              checked={@publisher.record?}
              phx-change="record-stream-change"
              disabled={!@publisher.recordings?}
            />
            <div class="w-11 h-6 bg-gray-300 peer-focus:outline-none peer-focus:ring-2 peer-focus:ring-indigo-500 rounded-full peer peer-checked:after:translate-x-5 peer-checked:after:border-white after:content-[''] after:absolute after:top-0.5 after:left-0.5 after:bg-white after:border-gray-300 after:border after:rounded-full after:h-5 after:w-5 after:transition-all peer-checked:bg-indigo-500 peer-disabled:opacity-50">
            </div>
          </label>
          <label for="lex-record-stream" class="text-xs text-nowrap">Record stream</label>
        </form>
      </div>
      <.modal id="settings-modal">
        <div class="flex items-stretch justify-between text-sm">
          <div class="text-[#606060] flex flex-col gap-4">
            <div class="font-bold text-[#0d0d0d]">Audio Settings</div>
            <div class="flex flex-col gap-4">
              <div class="flex gap-2.5 items-center">
                <label for="lex-echo-cancellation">Echo Cancellation</label>
                <input type="checkbox" id="lex-echo-cancellation" class="rounded-full" checked />
              </div>
              <div class="flex gap-2.5 items-center">
                <label for="lex-auto-gain-control">Auto Gain Control</label>
                <input type="checkbox" id="lex-auto-gain-control" class="rounded-full" checked />
              </div>
              <div class="flex gap-2.5 items-center">
                <label for="lex-noise-suppression">Noise Suppression</label>
                <input type="checkbox" id="lex-noise-suppression" class="rounded-full" checked />
              </div>
            </div>
          </div>
          <div class="transition-all duration-700 text-[#606060] flex flex-col gap-2">
            <div class="font-bold text-[#0d0d0d]">Video Settings</div>
            <div id="lex-video-static" phx-update="ignore" class="flex flex-col gap-2 items-end">
              <div class="flex items-center gap-2">
                <label for="lex-width">Width</label>
                <input
                  type="text"
                  id="lex-width"
                  value="1280"
                  class="rounded-lg disabled:text-gray-400 disabled:border-gray-400 focus:border-brand focus:outline-none focus:ring-0"
                />
              </div>
              <div class="flex items-center gap-2">
                <label for="lex-height">Height</label>
                <input
                  type="text"
                  id="lex-height"
                  value="720"
                  class="rounded-lg disabled:text-gray-400 disabled:border-gray-400 focus:border-brand focus:outline-none focus:ring-0"
                />
              </div>
              <div class="flex items-center gap-2">
                <label for="lex-fps">FPS</label>
                <input
                  type="text"
                  id="lex-fps"
                  value="30"
                  class="rounded-lg disabled:text-gray-400 disabled:border-gray-400 focus:border-brand focus:outline-none focus:ring-0"
                />
              </div>
            </div>
          </div>
        </div>
        <button
          id="lex-apply-button"
          class="w-full text-sm my-6 rounded-lg px-10 py-2.5 bg-brand disabled:bg-brand/50 hover:bg-brand/90 text-white font-bold"
          disabled
        >
          Apply
        </button>
        <div class="flex text-sm gap-4">
          <div class="flex items-center gap-2">
            <label for="lex-bitrate">Max Bitrate (kbps)</label>
            <input
              type="text"
              id="lex-bitrate"
              value="1500"
              class="rounded-lg disabled:text-gray-400 disabled:border-gray-400 focus:border-brand focus:outline-none focus:ring-0"
            />
          </div>
          <%= if @publisher.simulcast_supported? do %>
            <div class="flex gap-2.5 items-center text-sm">
              <label for="lex-simulcast">Simulcast</label>
              <input type="checkbox" id="lex-simulcast" class="rounded-full" />
            </div>
          <% else %>
            <div class="flex flex-col gap-2 text-sm">
              <div class="flex gap-2.5 items-center">
                <label for="lex-simulcast">Simulcast</label>
                <input type="checkbox" id="lex-simulcast" class="rounded-full bg-gray-300" disabled />
              </div>
              <p class="flex gap-2 text-sm leading-6 text-rose-600">
                <.icon name="hero-exclamation-circle-mini" class="mt-0.5 h-5 w-5 flex-none" />
                Simulcast requires server to be configured with H264 and/or VP8 codec
              </p>
            </div>
          <% end %>
        </div>
        <div id="lex-stats" class="flex justify-between w-full text-[#606060] text-sm mt-6">
          <div class="flex flex-col">
            <label for="lex-audio-bitrate">Audio Bitrate (kbps): </label>
            <span id="lex-audio-bitrate">0</span>
          </div>
          <div class="flex flex-col">
            <label for="lex-video-bitrate">Video Bitrate (kbps): </label>
            <span id="lex-video-bitrate">0</span>
          </div>
          <div class="flex flex-col">
            <label for="lex-packet-loss">Packet loss (%): </label>
            <span id="lex-packet-loss">0</span>
          </div>
          <div class="flex flex-col">
            <label for="lex-time">Time: </label>
            <span id="lex-time">00:00:00</span>
          </div>
        </div>
      </.modal>
    </div>
    """
  end

  @impl true
  def mount(_params, %{"publisher_id" => pub_id}, socket) do
    socket = assign(socket, publisher: nil)

    if connected?(socket) do
      ref = make_ref()
      send(socket.parent_pid, {__MODULE__, {:connected, ref, self(), %{publisher_id: pub_id}}})

      socket =
        receive do
          {^ref, %Publisher{id: ^pub_id} = publisher} ->
            Process.send_after(self(), :streams_info, 1000)
            codecs = publisher.video_codecs || PeerConnection.Configuration.default_video_codecs()
            publisher = %Publisher{publisher | simulcast_supported?: simulcast_supported?(codecs)}
            assign(socket, publisher: publisher)
        after
          5000 -> exit(:timeout)
        end

      {:ok, socket}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_info({:live_ex_webrtc, :keyframe_req, layer}, socket) do
    %{publisher: publisher} = socket.assigns

    # Non-simulcast tracks are always sent with "h" identifier
    # Hence, when we receive a keyframe request for "h", we must
    # check whether it's simulcast track or not.
    layer =
      if layer == "h" and publisher.video_track.rids == nil do
        nil
      else
        layer
      end

    if pc = publisher.pc do
      :ok = PeerConnection.send_pli(pc, publisher.video_track.id, layer)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:ex_webrtc, _pc, {:rtp, track_id, rid, packet}}, socket) do
    %{publisher: publisher} = socket.assigns

    if publisher.record?, do: Recorder.record(publisher.recorder, track_id, rid, packet)

    {kind, rid} =
      case publisher do
        %Publisher{video_track: %{id: ^track_id}} -> {:video, rid || "h"}
        %Publisher{audio_track: %{id: ^track_id}} -> {:audio, nil}
      end

    packet =
      if publisher.on_packet,
        do: publisher.on_packet.(publisher.id, kind, rid, packet, socket),
        else: packet

    {layer, msg} =
      case kind do
        :audio -> {"", {:live_ex_webrtc, kind, packet}}
        # for non simulcast tracks, push everything with "h" identifier
        :video -> {":#{rid}", {:live_ex_webrtc, kind, rid, packet}}
      end

    PubSub.broadcast(publisher.pubsub, "streams:#{kind}:#{publisher.id}:#{track_id}#{layer}", msg)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:ex_webrtc, _pid, {:connection_state_change, :connected}}, socket) do
    %{publisher: pub} = socket.assigns

    if pub.record? do
      [
        %{kind: :audio, receiver: %{track: audio_track}},
        %{kind: :video, receiver: %{track: video_track}}
      ] = PeerConnection.get_transceivers(pub.pc)

      Recorder.add_tracks(pub.recorder, [audio_track, video_track])
    end

    if pub.on_connected, do: pub.on_connected.(pub.id)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:ex_webrtc, _, _}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(:streams_info, socket) do
    %{publisher: publisher} = socket.assigns

    PubSub.broadcast(
      publisher.pubsub,
      "streams:info:#{publisher.id}",
      {:live_ex_webrtc, :info, publisher.audio_track, publisher.video_track}
    )

    Process.send_after(self(), :streams_info, 1_000)

    {:noreply, socket}
  end

  def handle_info(
        {:DOWN, _ref, :process, pc, _reason},
        %{assigns: %{publisher: %{pc: pc} = pub}} = socket
      ) do
    if pub.record? do
      recorder_result =
        Recorder.end_tracks(pub.recorder, [pub.audio_track.id, pub.video_track.id])

      if pub.on_recording_finished, do: pub.on_recording_finished.(pub.id, recorder_result)
    end

    if pub.on_disconnected, do: pub.on_disconnected.(pub.id)

    {:noreply, assign(socket, publisher: %Publisher{pub | streaming?: false})}
  end

  @impl true
  def handle_event("start-streaming", _, socket) do
    publisher = socket.assigns.publisher

    recorder =
      if publisher.record? == true and publisher.recorder == nil do
        {:ok, recorder} = Recorder.start_link(socket.assigns.publisher.recorder_opts)
        recorder
      else
        publisher.recorder
      end

    publisher = %Publisher{socket.assigns.publisher | streaming?: true, recorder: recorder}

    {:noreply,
     socket
     |> assign(publisher: publisher)
     |> push_event("start-streaming", %{})}
  end

  @impl true
  def handle_event("stop-streaming", _, socket) do
    {:noreply,
     socket
     |> assign(publisher: %Publisher{socket.assigns.publisher | streaming?: false})
     |> push_event("stop-streaming", %{})}
  end

  @impl true
  def handle_event("record-stream-change", params, socket) do
    record? = params["value"] == "on"

    {:noreply,
     socket
     |> assign(publisher: %Publisher{socket.assigns.publisher | record?: record?})}
  end

  @impl true
  def handle_event("offer", unsigned_params, socket) do
    %{publisher: publisher} = socket.assigns
    offer = SessionDescription.from_json(unsigned_params)
    {:ok, pc} = spawn_peer_connection(socket)
    Process.monitor(pc)

    :ok = PeerConnection.set_remote_description(pc, offer)

    [
      %{kind: :audio, receiver: %{track: audio_track}},
      %{kind: :video, receiver: %{track: video_track}}
    ] = PeerConnection.get_transceivers(pc)

    {:ok, answer} = PeerConnection.create_answer(pc)
    :ok = PeerConnection.set_local_description(pc, answer)
    :ok = gather_candidates(pc)
    answer = PeerConnection.get_local_description(pc)

    # subscribe now that we are initialized
    PubSub.subscribe(publisher.pubsub, "publishers:#{publisher.id}")

    new_publisher = %Publisher{
      publisher
      | pc: pc,
        audio_track: audio_track,
        video_track: video_track
    }

    {:noreply,
     socket
     |> assign(publisher: new_publisher)
     |> push_event("answer-#{publisher.id}", SessionDescription.to_json(answer))}
  end

  @impl true
  def handle_event("ice", "null", socket) do
    %{publisher: publisher} = socket.assigns

    case publisher do
      %Publisher{pc: nil} ->
        {:noreply, socket}

      %Publisher{pc: pc} ->
        :ok = PeerConnection.add_ice_candidate(pc, %ICECandidate{candidate: ""})
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("ice", unsigned_params, socket) do
    %{publisher: publisher} = socket.assigns

    case publisher do
      %Publisher{pc: nil} ->
        {:noreply, socket}

      %Publisher{pc: pc} ->
        cand =
          unsigned_params
          |> Jason.decode!()
          |> ExWebRTC.ICECandidate.from_json()

        :ok = PeerConnection.add_ice_candidate(pc, cand)

        {:noreply, socket}
    end
  end

  defp spawn_peer_connection(socket) do
    %{publisher: publisher} = socket.assigns

    pc_opts =
      [
        ice_servers: publisher.ice_servers,
        ice_ip_filter: publisher.ice_ip_filter,
        ice_port_range: publisher.ice_port_range,
        audio_codecs: publisher.audio_codecs,
        video_codecs: publisher.video_codecs
      ]
      |> Enum.reject(fn {_k, v} -> v == nil end)

    PeerConnection.start(pc_opts, publisher.pc_genserver_opts)
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

  defp simulcast_supported?(codecs) do
    Enum.all?(codecs, fn
      %RTPCodecParameters{mime_type: "video/VP8"} ->
        true

      %RTPCodecParameters{mime_type: "video/H264", sdp_fmtp_line: fmtp} when fmtp != nil ->
        fmtp.level_asymmetry_allowed == true and fmtp.packetization_mode == 1 and
          fmtp.profile_level_id == 0x42E01F

      _ ->
        false
    end)
  end
end
