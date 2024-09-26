defmodule LiveExWebRTC.Subscriber do
  use Phoenix.LiveComponent

  alias ExWebRTC.{MediaStreamTrack, PeerConnection, SessionDescription}

  def render(assigns) do
    ~H"""
    <video id={@id} phx-hook="Subscriber" controls autoplay muted></video>
    """
  end

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

  defp spawn_peer_connection(socket) do
    pc_opts =
      [
        ice_servers: socket.assigns[:ice_servers],
        audio_codecs: socket.assigns[:audio_codecs],
        video_codecs: socket.assigns[:video_codecs],
        ice_port_range: socket.assigns[:ice_port_range]
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
