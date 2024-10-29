defmodule LiveExWebRTC.Player do
  @moduledoc ~S'''
  Component for sending and playing audio and video via WebRTC from a Phoenix app to a browser (browser subscribes).

  It:
  * renders a single HTMLVideoElement
  * creates WebRTC PeerConnection both on the server and client side
  * connects those two peer connections negotiating a single audio and a single video track
  * attaches audio and video on the client side to the HTMLVideoElement
  * subscribes to the configured PubSub where it expects audio and video packets and sends them to the client side.

  When `LiveExWebRTC.Publisher` is used, audio an video packets are delivered automatically,
  assuming both components are configured with the same PubSub.

  If `LiveExWebRTC.Publisher` is not used, you should send packets to the
  `streams:audio:#{publisher_id}` and `streams:video:#{publisher_id}` topics.

  Keyframe requests are sent under `publishers:#{publisher_id}` topic.

  ## JavaScript Hook

  Player live view requires JavaScript hook to be registered under `Player` name.
  The hook can be created using `createPlayerHook` function.
  For example:

  ```javascript
  import { createPlayerHook } from "live_ex_webrtc";
  let Hooks = {};
  const iceServers = [{ urls: "stun:stun.l.google.com:19302" }];
  Hooks.Player = createPlayerHook(iceServers);
  let liveSocket = new LiveSocket("/live", Socket, {
    // ...
    hooks: Hooks
  });
  ```

  ## Examples

  ```elixir
  defmodule LiveTwitchWeb.StreamViewerLive do
    use LiveTwitchWeb, :live_view

    alias LiveExWebRTC.Player

    @impl true
    def render(assigns) do
    ~H"""
    <Player.live_render socket={@socket} player={@player} />
    """
    end

    @impl true
    def moount(_params, _session, socket) do
      socket = Player.attach(socket, id: "player", publisher_id: "publisher", pubsub: LiveTwitch.PubSub)
      {:ok, socket}
    end
  end
  ```
  '''
  use Phoenix.LiveView

  alias LiveExWebRTC.Player

  @type t() :: struct()

  defstruct id: nil,
            publisher_id: nil,
            pubsub: nil,
            pc: nil,
            audio_track_id: nil,
            video_track_id: nil,
            on_packet: nil,
            on_connected: nil,
            ice_servers: nil,
            ice_ip_filter: nil,
            ice_port_range: nil,
            audio_codecs: nil,
            video_codecs: nil,
            pc_genserver_opts: nil

  alias ExWebRTC.{ICECandidate, MediaStreamTrack, PeerConnection, SessionDescription}
  alias ExRTCP.Packet.PayloadFeedback.PLI
  alias Phoenix.PubSub

  attr(:socket, Phoenix.LiveView.Socket, required: true, doc: "Parent live view socket")

  attr(:player, __MODULE__,
    required: true,
    doc: """
    Player struct. It is used to pass player id and publisher id to the newly created live view via live view session.
    This data is then used to do a handshake between parent live view and child live view during which child live view receives
    the whole Player struct.
    """
  )

  attr(:class, :string, default: nil, doc: "CSS/Tailwind classes for styling HTMLVideoElement")

  @doc """
  Helper function for rendering Player live view.
  """
  def live_render(assigns) do
    ~H"""
    <%= live_render(@socket, __MODULE__, id: @player.id, session: %{
      "publisher_id" => @player.publisher_id,
      "class" => @class
    }) %>
    """
  end

  @doc """
  Attaches required hooks and creates `t:t/0` struct.

  Created struct is saved in socket's assigns and has to be passed to `LiveExWebRTC.Player.live_render/1`.

  Options:
  * `id` - player id. This is typically your user id (if there is users database).
  It is used to identify live view and generated HTML video player.
  * `publisher_id` - publisher id that this player is going to subscribe to.
  * `pubsub` - a pubsub that player live view will subscribe to for audio and video packets. See module doc for more.
  * `on_connected` - callback called when the underlying peer connection changes its state to the `:connected`
  * `on_packet` - callback called for each audio and video RTP packet. Can be used to modify the packet before sending via WebRTC to the other side.
  * `ice_servers` - a list of `t:ExWebRTC.PeerConnection.Configuration.ice_server/0`,
  * `ice_ip_filter` - `t:ExICE.ICEAgent.ip_filter/0`,
  * `ice_port_range` - `t:Enumerable.t(non_neg_integer())/1`,
  * `audio_codecs` - a list of `t:ExWebRTC.RTPCodecParameters.t/0`,
  * `video_codecs` - a list of `t:ExWebRTC.RTPCodecParameters.t/0`,
  * `pc_genserver_opts` - `t:GenServer.options/0` for the underlying `ExWebRTC.PeerConnection` process.
  * `class` - a list of CSS/Tailwind classes that will be applied to the HTMLVideoPlayer. Defaults to "".
  """
  @spec attach(Phoenix.LiveView.Socket.t(), Keyword.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket, opts) do
    opts =
      Keyword.validate!(opts, [
        :id,
        :publisher_id,
        :pc_genserver_opts,
        :pubsub,
        :on_connected,
        :on_packet,
        :ice_servers,
        :ice_ip_filter,
        :ice_port_range,
        :audio_codecs,
        :video_codecs
      ])

    player = %Player{
      id: Keyword.fetch!(opts, :id),
      publisher_id: Keyword.fetch!(opts, :publisher_id),
      pubsub: Keyword.fetch!(opts, :pubsub),
      on_packet: Keyword.get(opts, :on_packet),
      on_connected: Keyword.get(opts, :on_connected),
      ice_servers: Keyword.get(opts, :ice_servers, [%{urls: "stun:stun.l.google.com:19302"}]),
      ice_ip_filter: Keyword.get(opts, :ice_ip_filter),
      ice_port_range: Keyword.get(opts, :ice_port_range),
      audio_codecs: Keyword.get(opts, :audio_codecs),
      video_codecs: Keyword.get(opts, :video_codecs),
      pc_genserver_opts: Keyword.get(opts, :pc_genserver_opts, [])
    }

    socket
    |> assign(player: player)
    |> attach_hook(:handshake, :handle_info, &handshake/2)
  end

  defp handshake({__MODULE__, {:connected, ref, child_pid, _meta}}, socket) do
    # child live view is connected, send it player struct
    send(child_pid, {ref, socket.assigns.player})
    {:halt, socket}
  end

  defp handshake(_msg, socket) do
    {:cont, socket}
  end

  ## CALLBACKS

  @impl true
  def render(%{player: nil} = assigns) do
    ~H"""
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <video id={@player.id} phx-hook="Player" class={@class} controls autoplay muted></video>
    """
  end

  @impl true
  def mount(_params, %{"publisher_id" => pub_id, "class" => class}, socket) do
    socket = assign(socket, class: class, player: nil)

    if connected?(socket) do
      ref = make_ref()
      send(socket.parent_pid, {__MODULE__, {:connected, ref, self(), %{publisher_id: pub_id}}})

      socket =
        receive do
          {^ref, %Player{publisher_id: ^pub_id} = player} ->
            assign(socket, player: player)
        after
          5000 -> exit(:timeout)
        end

      {:ok, socket}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_info({:ex_webrtc, _pid, {:connection_state_change, :connected}}, socket) do
    %{player: player} = socket.assigns
    PubSub.subscribe(player.pubsub, "streams:audio:#{player.publisher_id}")
    PubSub.subscribe(player.pubsub, "streams:video:#{player.publisher_id}")
    broadcast_keyframe_req(socket)
    if player.on_connected, do: player.on_connected.(player.publisher_id)

    {:noreply, socket}
  end

  def handle_info({:ex_webrtc, _pc, {:rtcp, packets}}, socket) do
    # Browser, we are sending to, requested a keyframe.
    # Forward this request to the publisher.
    if Enum.any?(packets, fn {_, packet} -> match?(%PLI{}, packet) end) do
      broadcast_keyframe_req(socket)
    end

    {:noreply, socket}
  end

  def handle_info({:ex_webrtc, _pid, _}, socket) do
    {:noreply, socket}
  end

  def handle_info({:live_ex_webrtc, :audio, packet}, socket) do
    %{player: player} = socket.assigns

    packet =
      if player.on_packet,
        do: player.on_packet.(player.publisher_id, :audio, packet),
        else: packet

    PeerConnection.send_rtp(player.pc, player.audio_track_id, packet)
    {:noreply, socket}
  end

  def handle_info({:live_ex_webrtc, :video, packet}, socket) do
    %{player: player} = socket.assigns

    packet =
      if player.on_packet,
        do: player.on_packet.(player.publisher_id, :video, packet),
        else: packet

    PeerConnection.send_rtp(player.pc, player.video_track_id, packet)
    {:noreply, socket}
  end

  @impl true
  def handle_event("offer", unsigned_params, socket) do
    %{player: player} = socket.assigns

    offer = SessionDescription.from_json(unsigned_params)
    {:ok, pc} = spawn_peer_connection(socket)

    :ok = PeerConnection.set_remote_description(pc, offer)

    stream_id = MediaStreamTrack.generate_stream_id()
    audio_track = MediaStreamTrack.new(:audio, [stream_id])
    video_track = MediaStreamTrack.new(:video, [stream_id])
    {:ok, _sender} = PeerConnection.add_track(pc, audio_track)
    {:ok, _sender} = PeerConnection.add_track(pc, video_track)
    {:ok, answer} = PeerConnection.create_answer(pc)
    :ok = PeerConnection.set_local_description(pc, answer)
    :ok = gather_candidates(pc)
    answer = PeerConnection.get_local_description(pc)

    new_player = %Player{
      player
      | pc: pc,
        audio_track_id: audio_track.id,
        video_track_id: video_track.id
    }

    {:noreply,
     socket
     |> assign(player: new_player)
     |> push_event("answer-#{player.id}", SessionDescription.to_json(answer))}
  end

  @impl true
  def handle_event("ice", "null", socket) do
    %{player: player} = socket.assigns

    case player do
      %Player{pc: nil} ->
        {:noreply, socket}

      %Player{pc: pc} ->
        :ok = PeerConnection.add_ice_candidate(pc, %ICECandidate{candidate: ""})
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("ice", unsigned_params, socket) do
    %{player: player} = socket.assigns

    case player do
      %Player{pc: nil} ->
        {:noreply, socket}

      %Player{pc: pc} ->
        cand =
          unsigned_params
          |> Jason.decode!()
          |> ExWebRTC.ICECandidate.from_json()

        :ok = PeerConnection.add_ice_candidate(pc, cand)

        {:noreply, socket}
    end
  end

  defp spawn_peer_connection(socket) do
    %{player: player} = socket.assigns

    pc_opts =
      [
        ice_servers: player.ice_servers,
        ice_ip_filter: player.ice_ip_filter,
        ice_port_range: player.ice_port_range,
        audio_codecs: player.audio_codecs,
        video_codecs: player.video_codecs
      ]
      |> Enum.reject(fn {_k, v} -> v == nil end)

    PeerConnection.start_link(pc_opts, player.pc_genserver_opts)
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

  defp broadcast_keyframe_req(socket) do
    %{player: player} = socket.assigns

    PubSub.broadcast(
      player.pubsub,
      "publishers:#{player.publisher_id}",
      {:live_ex_webrtc, :keyframe_req}
    )
  end
end
