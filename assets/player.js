export const LiveExWebRTCPlayer = {
  async mounted() {
    const pc = new RTCPeerConnection();
    pc.ontrack = (ev) => (this.el.srcObject = ev.streams[0]);
    pc.addTransceiver("audio", { direction: "recvonly" });
    pc.addTransceiver("video", { direction: "recvonly" });

    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);

    this.handleEvent(
      "answer",
      async (answer) => await pc.setRemoteDescription(answer)
    );

    this.pushEventTo(this.el, "offer", offer);
  },
};
