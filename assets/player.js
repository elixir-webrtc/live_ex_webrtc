export function createPlayerHook(iceServers = []) {
  return {
    async mounted() {
      const view = this;

      view.handleEvent(
        `connect-${view.el.id}`,
        async () => await view.connect(view)
      );

      const eventName = "answer" + "-" + view.el.id;
      view.handleEvent(eventName, async (answer) => {
        if (view.pc) {
          await view.pc.setRemoteDescription(answer);
        }
      });

      view.videoQuality = document.getElementById("lexp-video-quality");
      view.videoQuality.onchange = () => {
        view.pushEventTo(view.el, "layer", view.videoQuality.value);
      };
    },

    async connect(view) {
      view.el.srcObject = undefined;
      view.pc = new RTCPeerConnection({ iceServers: iceServers });

      view.pc.onicecandidate = (ev) => {
        view.pushEventTo(view.el, "ice", JSON.stringify(ev.candidate));
      };

      view.pc.ontrack = (ev) => {
        if (!view.el.srcObject) {
          view.el.srcObject = ev.streams[0];
        }
      };
      view.pc.addTransceiver("audio", { direction: "recvonly" });
      view.pc.addTransceiver("video", { direction: "recvonly" });

      const offer = await view.pc.createOffer();
      await view.pc.setLocalDescription(offer);

      view.pushEventTo(view.el, "offer", offer);
    }
  };
}
