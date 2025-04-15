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

  If `LiveExWebRTC.Publisher` is not used, you need to send track information and packets,
  and receive keyframe requests manually using specific PubSub topics.
  See `LiveExWebRTC.Publisher` module doc for more.

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

  ## Simulcast

  Simulcast requires video codecs to be H264 (packetization mode 1) and/or VP8.
  See `LiveExWebRTC.Publisher` module doc for more.

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
    def mount(_params, _session, socket) do
      socket = Player.attach(socket, id: "player", publisher_id: "publisher", pubsub: LiveTwitch.PubSub)
      {:ok, socket}
    end
  end
  ```
  '''
  use Phoenix.LiveView

  require Logger

  alias ExWebRTC.RTPCodecParameters
  alias ExWebRTC.RTP.{H264, VP8}
  alias LiveExWebRTC.Player

  @type on_connected() :: (publisher_id :: String.t() -> any())

  @type on_packet() ::
          (publisher_id :: String.t(),
           packet_type :: :audio | :video,
           packet :: ExRTP.Packet.t(),
           socket :: Phoenix.LiveView.Socket.t() ->
             packet :: ExRTP.Packet.t())

  @type t() :: struct()

  @check_lock_timeout_ms 3000
  @max_lock_timeout_ms 3000

  defstruct id: nil,
            publisher_id: nil,
            publisher_audio_track: nil,
            publisher_video_track: nil,
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
            pc_genserver_opts: nil,
            munger: nil,
            layer: nil,
            target_layer: nil,
            video_layers: [],
            # codec that will be used for video sending
            video_send_codec: nil,
            last_seen: nil,
            locked: false,
            lock_timer: nil

  alias ExWebRTC.{ICECandidate, MediaStreamTrack, PeerConnection, RTP.Munger, SessionDescription}
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

  attr(:class, :string, default: nil, doc: "CSS/Tailwind classes for styling container")

  attr(:video_class, :string,
    default: nil,
    doc: "CSS/Tailwind classes for styling HTMLVideoElement"
  )

  @doc """
  Helper function for rendering Player live view.
  """
  def live_render(assigns) do
    ~H"""
    {live_render(@socket, __MODULE__,
      id: "#{@player.id}-lv",
      session: %{
        "publisher_id" => @player.publisher_id,
        "class" => @class,
        "video_class" => @video_class
      }
    )}
    """
  end

  @doc """
  Attaches required hooks and creates `t:t/0` struct.

  Created struct is saved in socket's assigns and has to be passed to `LiveExWebRTC.Player.live_render/1`.

  Options:
  * `id` [**required**] - player id. This is typically your user id (if there is users database).
  It is used to identify live view and generated HTML video player.
  * `publisher_id` [**required**] - publisher id that this player is going to subscribe to.
  * `pubsub` [**required**] - a pubsub that player live view will use for receiving audio and video packets. See module doc for more info.
  * `on_connected` - callback called when the underlying peer connection changes its state to the `:connected`. See `t:on_connected/0`.
  * `on_packet` - callback called for each audio and video RTP packet. Can be used to modify the packet before sending via WebRTC to the other side. See `t:on_packet/0`.
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
    <div class={@class}>
      <div class="group inline-block relative w-full h-full">
        <video
          id={@player.id}
          phx-hook="Player"
          class={["w-full h-full", @video_class]}
          controls
          muted
        >
        </video>

        <div class={[
          "w-full h-full absolute top-0 left-0 z-40 flex items-center justify-center bg-black/30",
          @display_settings
        ]}>
          <div
            class="p-8 pr-12 bg-stone-900/90 h-fit rounded-lg relative"
            phx-click-away="toggle-settings"
          >
            <div class="flex gap-4 items-center">
              <label class="cursor-pointer text-white text-nowrap text-sm" for="lexp-video-quality">
                Video Quality
              </label>
              <select
                id="lexp-video-quality"
                class="rounded-lg text-sm disabled:text-gray-400 disabled:border-gray-400 focus:outline-none focus:ring-0 bg-transparent text-indigo-400 border-indigo-400 focus:border-indigo-400 min-w-[128px]"
              >
                <%= for {id, layer} <- @player.video_layers do %>
                  <option :if={id == @player.layer} value={id} selected>{layer}</option>
                  <option :if={id != @player.layer} value={id}>{layer}</option>
                <% end %>
              </select>
            </div>
            <button
              class="top-2 right-2 absolute p-2 hover:bg-stone-800 rounded-lg"
              phx-click="toggle-settings"
            >
              <span class="hero-x-mark block w-4 h-4 text-white" />
            </button>
          </div>
        </div>

        <button
          phx-click="toggle-settings"
          class="absolute top-6 left-6 duration-300 ease-in-out group-hover:visible invisible transition-opacity opacity-0 group-hover:opacity-100 rounded-lg bg-stone-700 hover:bg-stone-800 p-2"
        >
          <span class="hero-cog-8-tooth text-white w-6 h-6 block" />
        </button>
      </div>
    </div>
    """
  end

  @impl true
  def mount(
        _params,
        %{"publisher_id" => pub_id, "class" => class, "video_class" => video_class},
        socket
      ) do
    socket = assign(socket, class: class, player: nil, video_class: video_class)

    if connected?(socket) do
      ref = make_ref()
      send(socket.parent_pid, {__MODULE__, {:connected, ref, self(), %{publisher_id: pub_id}}})

      socket =
        receive do
          {^ref, %Player{publisher_id: ^pub_id} = player} ->
            PubSub.subscribe(player.pubsub, "streams:info:#{player.publisher_id}")
            assign(socket, player: player, display_settings: "hidden")
        after
          5000 -> exit(:timeout)
        end

      {:ok, socket}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_info(
        {:ex_webrtc, pc, {:connection_state_change, :connected}},
        %{assigns: %{player: %{pc: pc}}} = socket
      ) do
    %{player: player} = socket.assigns

    # subscribe only if we managed to negotiate tracks
    if player.audio_track_id != nil do
      PubSub.subscribe(
        player.pubsub,
        "streams:audio:#{player.publisher_id}:#{player.publisher_audio_track.id}"
      )
    end

    if player.video_track_id != nil do
      PubSub.subscribe(
        player.pubsub,
        "streams:video:#{player.publisher_id}:#{player.publisher_video_track.id}:#{player.layer}"
      )

      broadcast_keyframe_req(socket)
    end

    if player.on_connected, do: player.on_connected.(player.publisher_id)

    {:noreply, socket}
  end

  @impl true
  def handle_info(
        {:ex_webrtc, pc, {:connection_state_change, :failed}},
        %{assigns: %{player: %{pc: pc}}}
      ) do
    exit(:pc_failed)
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

  @impl true
  def handle_info({:live_ex_webrtc, :info, publisher_audio_track, publisher_video_track}, socket) do
    %{player: player} = socket.assigns

    case player do
      %Player{
        publisher_audio_track: ^publisher_audio_track,
        publisher_video_track: ^publisher_video_track
      } ->
        # tracks are the same, update last_seen and do nothing
        player = %Player{player | last_seen: System.monotonic_time(:millisecond)}
        socket = assign(socket, player: player)
        {:noreply, socket}

      %Player{locked: true} ->
        # Different tracks but we are still receiving updates from old publisher. Ignore.
        {:noreply, socket}

      %Player{
        publisher_audio_track: old_publisher_audio_track,
        publisher_video_track: old_publisher_video_track,
        video_layers: old_layers,
        locked: false
      } ->
        if player.pc, do: PeerConnection.close(player.pc)

        if player.lock_timer do
          Process.cancel_timer(player.lock_timer)

          # flush mailbox
          receive do
            :check_lock -> :ok
          after
            0 -> :ok
          end
        end

        video_layers = (publisher_video_track && publisher_video_track.rids) || ["h"]

        video_layers =
          Enum.map(video_layers, fn
            "h" -> {"h", "high"}
            "m" -> {"m", "medium"}
            "l" -> {"l", "low"}
          end)

        player = %Player{
          player
          | publisher_audio_track: publisher_audio_track,
            publisher_video_track: publisher_video_track,
            pc: nil,
            layer: "h",
            target_layer: "h",
            video_layers: video_layers,
            munger: nil,
            last_seen: System.monotonic_time(:millisecond),
            locked: true,
            lock_timer: Process.send_after(self(), :check_lock, @check_lock_timeout_ms)
        }

        socket = assign(socket, :player, player)

        if old_publisher_audio_track != nil or old_publisher_video_track != nil do
          PubSub.unsubscribe(
            player.pubsub,
            "streams:audio:#{player.publisher_id}:#{old_publisher_audio_track.id}"
          )

          Enum.each(old_layers, fn {id, _layer} ->
            PubSub.unsubscribe(
              player.pubsub,
              "streams:video:#{player.publisher_id}:#{old_publisher_video_track.id}:#{id}"
            )
          end)
        end

        if publisher_audio_track != nil or publisher_video_track != nil do
          socket = push_event(socket, "connect-#{player.id}", %{})
          {:noreply, socket}
        else
          {:noreply, socket}
        end
    end
  end

  @impl true
  def handle_info({:live_ex_webrtc, :bye, publisher_audio_track, publisher_video_track}, socket) do
    %{player: player} = socket.assigns

    case player do
      %Player{
        publisher_audio_track: ^publisher_audio_track,
        publisher_video_track: ^publisher_video_track
      } ->
        player = %Player{player | locked: false}
        socket = assign(socket, player: player)
        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:live_ex_webrtc, :audio, packet}, socket) do
    %{player: player} = socket.assigns

    packet =
      if player.on_packet,
        do: player.on_packet.(player.publisher_id, :audio, packet, socket),
        else: packet

    PeerConnection.send_rtp(player.pc, player.audio_track_id, packet)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:live_ex_webrtc, :video, rid, packet}, socket) do
    %{player: player} = socket.assigns

    packet =
      if player.on_packet,
        do: player.on_packet.(player.publisher_id, :video, packet),
        else: packet

    cond do
      rid == player.layer ->
        {packet, munger} = Munger.munge(player.munger, packet)
        player = %Player{player | munger: munger}
        socket = assign(socket, player: player)
        :ok = PeerConnection.send_rtp(player.pc, player.video_track_id, packet)
        {:noreply, socket}

      rid == player.target_layer ->
        if keyframe?(player.video_send_codec, packet) == true do
          munger = Munger.update(player.munger)
          {packet, munger} = Munger.munge(munger, packet)

          PeerConnection.send_rtp(player.pc, player.video_track_id, packet)

          PubSub.unsubscribe(
            socket.assigns.player.pubsub,
            "streams:video:#{player.publisher_id}:#{player.publisher_video_track.id}:#{player.layer}"
          )

          flush_layer(player.layer)

          player = %Player{player | munger: munger, layer: rid}
          socket = assign(socket, player: player)
          {:noreply, socket}
        else
          {:noreply, socket}
        end

      true ->
        Logger.warning("Unexpected packet. Ignoring.")
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:check_lock, %{assigns: %{player: %Player{locked: true} = player}} = socket) do
    now = System.monotonic_time(:millisecond)

    if now - socket.assigns.player.last_seen > @max_lock_timeout_ms do
      # unlock i.e. allow for track update
      player = %Player{player | lock_timer: nil, locked: false}
      socket = assign(socket, :player, player)
      {:noreply, socket}
    else
      timer = Process.send_after(self(), :check_lock, @check_lock_timeout_ms)
      player = %Player{player | lock_timer: timer}
      socket = assign(socket, :player, player)
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:check_lock, socket) do
    player = %Player{socket.assigns.player | lock_timer: nil}
    socket = assign(socket, :player, player)
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle-settings", _params, socket) do
    socket =
      case socket.assigns do
        %{display_settings: "hidden"} ->
          assign(socket, :display_settings, "flex")

        %{display_settings: "flex"} ->
          assign(socket, :display_settings, "hidden")
      end

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
    {:ok, audio_sender} = PeerConnection.add_track(pc, audio_track)
    {:ok, video_sender} = PeerConnection.add_track(pc, video_track)
    {:ok, answer} = PeerConnection.create_answer(pc)
    :ok = PeerConnection.set_local_description(pc, answer)
    :ok = gather_candidates(pc)
    answer = PeerConnection.get_local_description(pc)

    transceivers = PeerConnection.get_transceivers(pc)
    video_tr = Enum.find(transceivers, fn tr -> tr.sender.id == video_sender.id end)
    audio_tr = Enum.find(transceivers, fn tr -> tr.sender.id == audio_sender.id end)

    # check if tracks were negotiated successfully
    video_negotiated? = video_tr && video_tr.current_direction not in [:recvonly, :inactive]
    audio_negotiated? = audio_tr && audio_tr.current_direction not in [:recvonly, :inactive]

    new_player = %Player{
      player
      | pc: pc,
        audio_track_id: audio_negotiated? && audio_track.id,
        video_track_id: video_negotiated? && video_track.id,
        munger: video_negotiated? && Munger.new(List.first(video_tr.codecs)),
        video_send_codec: video_negotiated? && List.first(video_tr.codecs)
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

  @impl true
  def handle_event("layer", layer, socket) when layer in ["l", "m", "h"] do
    %{player: player} = socket.assigns

    if player.layer == layer do
      {:noreply, socket}
    else
      # this shouldn't be needed but just to make sure we won't duplicate subscription
      PubSub.unsubscribe(
        player.pubsub,
        "streams:video:#{player.publisher_id}:#{player.publisher_video_track.id}:#{layer}"
      )

      PubSub.subscribe(
        player.pubsub,
        "streams:video:#{player.publisher_id}:#{player.publisher_video_track.id}:#{layer}"
      )

      player = %Player{player | target_layer: layer}

      socket = assign(socket, player: player)
      broadcast_keyframe_req(socket)
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

    layer = player.target_layer || player.layer

    PubSub.broadcast(
      player.pubsub,
      "publishers:#{player.publisher_id}",
      {:live_ex_webrtc, :keyframe_req, layer}
    )
  end

  defp keyframe?(%RTPCodecParameters{mime_type: "video/H264"}, packet), do: H264.keyframe?(packet)
  defp keyframe?(%RTPCodecParameters{mime_type: "video/VP8"}, packet), do: VP8.keyframe?(packet)

  defp flush_layer(layer) do
    receive do
      {:live_ex_webrtc, :video, ^layer, _packet} -> flush_layer(layer)
    after
      0 -> :ok
    end
  end
end
