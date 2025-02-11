export function createPlayerHook(iceServers = []) {
  return {
    async mounted() {
      this.videoQuality = document.getElementById("lexp-video-quality");
      this.videoQuality.onchange = () => {
        this.pushEventTo(this.el, "layer", this.videoQuality.value);
      };

      this.pc = new RTCPeerConnection({ iceServers: iceServers });

      this.pc.onicecandidate = (ev) => {
        this.pushEventTo(this.el, "ice", JSON.stringify(ev.candidate));
      };

      this.pc.ontrack = (ev) => {
        if (!this.el.srcObject) {
          this.el.srcObject = ev.streams[0];
        }
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
