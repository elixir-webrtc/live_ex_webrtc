defmodule LiveExWebRTC.Publisher do
  use Phoenix.LiveComponent

  alias ExWebRTC.{PeerConnection, SessionDescription}

  def render(assigns) do
    ~H"""
    <div id={@id} phx-hook="LiveExWebRTCPublisher" class="h-full w-full flex justify-between gap-6">
      <div class="w-full flex flex-col">
        <details>
          <summary class="font-bold text-[#0d0d0d] py-2.5">Devices</summary>
          <div class="text-[#606060] flex flex-col gap-6 py-2.5">
            <div class="flex gap-2.5 items-center">
              <label for="audioDevices" class="font-medium">Audio Device</label>
              <select
                id="audioDevices"
                class="rounded-lg focus:border-brand focus:outline-none focus:ring-0"
              >
              </select>
            </div>
            <div class="flex gap-2.5 items-center">
              <label for="videoDevices" class="">Video Device</label>
              <select
                id="videoDevices"
                class="rounded-lg focus:border-brand focus:outline-none focus:ring-0"
              >
              </select>
            </div>
          </div>
        </details>
        <details>
          <summary class="font-bold text-[#0d0d0d] py-2.5">Audio Settings</summary>
          <div class="text-[#606060] flex flex-col gap-6 py-2.5">
            <div class="flex gap-2.5 items-center">
              <label for="echoCancellation">Echo Cancellation</label>
              <input type="checkbox" id="echoCancellation" class="rounded-full" checked />
            </div>
            <div class="flex gap-2.5 items-center">
              <label for="autoGainControl">Auto Gain Control</label>
              <input type="checkbox" id="autoGainControl" class="rounded-full" checked />
            </div>
            <div class="flex gap-2.5 items-center">
              <label for="noiseSuppression">Noise Suppression</label>
              <input type="checkbox" id="noiseSuppression" class="rounded-full" checked />
            </div>
          </div>
        </details>
        <div class="py-2.5">
          <button
            id="button"
            class="rounded-lg w-full bg-brand/100 px-2.5 py-2.5 hover:bg-brand/90 text-white font-bold"
          >
            Start streaming
          </button>
        </div>
        <div id="videoplayer-wrapper" class="flex flex-1 flex-col min-h-0 py-2.5">
          <video id="previewPlayer" class="m-auto rounded-lg bg-black h-full" autoplay controls muted>
          </video>
        </div>
      </div>
    </div>
    """
  end

  def handle_event("offer", unsigned_params, socket) do
    offer = SessionDescription.from_json(unsigned_params)
    {:ok, pc} = spawn_peer_connection(socket)

    :ok = PeerConnection.set_remote_description(pc, offer)

    [
      %{kind: :audio, receiver: %{track: audio_track}},
      %{kind: :video, receiver: %{track: video_track}}
    ] = PeerConnection.get_transceivers(pc)

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
