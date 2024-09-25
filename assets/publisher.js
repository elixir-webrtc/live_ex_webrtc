export const LiveExWebRTCPublisher = {
  async mounted() {
    console.log("mounted");
    const view = this;

    const mediaConstraints = {
      video: {
        width: { ideal: 1280 },
        height: { ideal: 720 },
        frameRate: { ideal: 24 },
      },
      audio: true,
    };

    this.button = document.getElementById("button");

    this.echoCancellation = document.getElementById("echoCancellation");
    this.autoGainControl = document.getElementById("autoGainControl");
    this.noiseSuppression = document.getElementById("noiseSuppression");

    this.audioDevices = document.getElementById("audioDevices");
    this.videoDevices = document.getElementById("videoDevices");

    this.previewPlayer = document.getElementById("previewPlayer");

    this.audioDevices.onchange = function () {
      view.setupStream(view);
    };

    this.videoDevices.onchange = function () {
      view.setupStream(view);
    };

    this.button.onclick = function () {
      view.startStreaming(view);
    };

    // ask for permissions
    this.localStream = await navigator.mediaDevices.getUserMedia(
      mediaConstraints
    );

    console.log(`Obtained stream with id: ${this.localStream.id}`);

    // enumerate devices
    const devices = await navigator.mediaDevices.enumerateDevices();
    devices.forEach((device) => {
      if (device.kind === "videoinput") {
        this.videoDevices.options[videoDevices.options.length] = new Option(
          device.label,
          device.deviceId
        );
      } else if (device.kind === "audioinput") {
        this.audioDevices.options[audioDevices.options.length] = new Option(
          device.label,
          device.deviceId
        );
      }
    });

    // for some reasons, firefox loses labels after closing the stream
    // so we close it after filling audio/video devices selects
    this.closeStream(view);

    // setup preview
    await this.setupStream(view);
  },

  closeStream(view) {
    if (view.localStream != undefined) {
      console.log(`Closing stream with id: ${view.localStream.id}`);
      view.localStream.getTracks().forEach((track) => track.stop());
      view.localStream = undefined;
    }
  },

  async setupStream(view) {
    if (view.localStream != undefined) {
      view.closeStream(view);
    }

    const videoDevice = view.videoDevices.value;
    const audioDevice = view.audioDevices.value;

    console.log(
      `Setting up stream: audioDevice: ${audioDevice}, videoDevice: ${videoDevice}`
    );

    view.localStream = await navigator.mediaDevices.getUserMedia({
      video: {
        deviceId: { exact: videoDevice },
        width: { ideal: 1280 },
        height: { ideal: 720 },
      },
      audio: {
        deviceId: { exact: audioDevice },
        echoCancellation: view.echoCancellation.checked,
        autoGainControl: view.autoGainControl.checked,
        noiseSuppression: view.noiseSuppression.checked,
      },
    });

    console.log(`Obtained stream with id: ${view.localStream.id}`);

    view.previewPlayer.srcObject = view.localStream;
  },

  async startStreaming(view) {
    view.pc = new RTCPeerConnection();
    view.pc.addTrack(view.localStream.getAudioTracks()[0], view.localStream);
    view.pc.addTrack(view.localStream.getVideoTracks()[0], view.localStream);

    const offer = await view.pc.createOffer();
    await view.pc.setLocalDescription(offer);

    const eventName = "answer" + "-" + view.el.id;
    view.handleEvent(eventName, async (answer) => {
      console.log("got answer");
      await view.pc.setRemoteDescription(answer);
    });

    view.pushEventTo(view.el, "offer", offer);
  },
};
