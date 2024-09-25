export const LiveExWebRTCPublisher = {
  async mounted() {
    const view = this;

    this.audioDevices = document.getElementById("audioDevices");
    this.videoDevices = document.getElementById("videoDevices");

    this.echoCancellation = document.getElementById("echoCancellation");
    this.autoGainControl = document.getElementById("autoGainControl");
    this.noiseSuppression = document.getElementById("noiseSuppression");

    this.width = document.getElementById("width");
    this.height = document.getElementById("height");
    this.fps = document.getElementById("fps");
    this.bitrate = document.getElementById("bitrate");

    this.previewPlayer = document.getElementById("previewPlayer");

    this.audioApplyButton = document.getElementById("audioApplyButton");
    this.videoApplyButton = document.getElementById("videoApplyButton");
    this.button = document.getElementById("button");

    this.audioDevices.onchange = function () {
      view.setupStream(view);
    };

    this.videoDevices.onchange = function () {
      view.setupStream(view);
    };

    this.audioApplyButton.onclick = function () {
      view.setupStream(view);
    };

    this.videoApplyButton.onclick = function () {
      view.setupStream(view);
    };

    this.button.onclick = function () {
      view.startStreaming(view);
    };

    await this.findDevices(this);
  },

  async findDevices(view) {
    // ask for permissions
    view.localStream = await navigator.mediaDevices.getUserMedia({
      video: true,
      audio: true,
    });

    console.log(`Obtained stream with id: ${view.localStream.id}`);

    // enumerate devices
    const devices = await navigator.mediaDevices.enumerateDevices();
    devices.forEach((device) => {
      if (device.kind === "videoinput") {
        view.videoDevices.options[videoDevices.options.length] = new Option(
          device.label,
          device.deviceId
        );
      } else if (device.kind === "audioinput") {
        view.audioDevices.options[audioDevices.options.length] = new Option(
          device.label,
          device.deviceId
        );
      }
    });

    // for some reasons, firefox loses labels after closing the stream
    // so we close it after filling audio/video devices selects
    view.closeStream(view);

    // setup preview
    await view.setupStream(view);
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
        width: view.width.value,
        height: view.height.value,
        frameRate: view.fps.value,
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

    // set max bitrate
    view.pc
      .getSenders()
      .filter((sender) => sender.track.kind === "video")
      .forEach(async (sender) => {
        const params = sender.getParameters();
        params.encodings[0].maxBitrate = view.bitrate.value * 1024;
        await sender.setParameters(params);
      });

    const offer = await view.pc.createOffer();
    await view.pc.setLocalDescription(offer);

    const eventName = "answer" + "-" + view.el.id;
    view.handleEvent(eventName, async (answer) => {
      await view.pc.setRemoteDescription(answer);
    });

    view.pushEventTo(view.el, "offer", offer);
  },
};
