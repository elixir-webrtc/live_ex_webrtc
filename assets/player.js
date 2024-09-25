export const LiveExWebRTCPlayer = {
  async mounted() {
    this.pc = new RTCPeerConnection();
    this.pc.ontrack = (ev) => {
      console.log("ontrack");
      this.el.srcObject = ev.streams[0];
    };
    this.pc.addTransceiver("audio", { direction: "recvonly" });
    this.pc.addTransceiver("video", { direction: "recvonly" });

    const offer = await this.pc.createOffer();
    await this.pc.setLocalDescription(offer);

    const eventName = "answer" + "-" + this.el.id;
    this.handleEvent(eventName, async (answer) => {
      await this.pc.setRemoteDescription(answer);
    });

    this.pushEventTo(this.el, "offer", offer);
  },
};
