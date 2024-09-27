export function createSubscriberHook(iceServers = []) {
  return {
    async mounted() {
      this.pc = new RTCPeerConnection({ iceServers: iceServers });

      this.pc.onicecandidate = (ev) => {
        this.pushEventTo(this.el, "ice", JSON.stringify(ev.candidate));
      };

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
}
