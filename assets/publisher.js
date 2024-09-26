export const Publisher = {
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

    // handle remote events
    view.handleEvent(`answer-${view.el.id}`, async (answer) => {
      if (view.pc) {
        await view.pc.setRemoteDescription(answer);
      } else {
        console.warn("Received SDP cnswer but there is no PC. Ignoring.");
      }
    });

    view.handleEvent(`ice-${view.el.id}`, async (cand) => {
      if (view.pc) {
        await view.pc.addIceCandidate(JSON.parse(cand));
      } else {
        console.warn("Received ICE candidate but there is no PC. Ignoring.");
      }
    });

    try {
      await this.findDevices(this);
      try {
        await view.setupStream(view);
        button.disabled = false;
        audioApplyButton.disabled = false;
        videoApplyButton.disabled = false;
      } catch (error) {
        console.error("Couldn't setup stream");
      }
    } catch (error) {
      console.error("Couldn't find audio and/or video devices");
    }
  },

  disableControls(view) {
    view.audioDevices.disabled = true;
    view.videoDevices.disabled = true;
    view.echoCancellation.disabled = true;
    view.autoGainControl.disabled = true;
    view.noiseSuppression.disabled = true;
    view.width.disabled = true;
    view.height.disabled = true;
    view.fps.disabled = true;
    view.audioApplyButton.disabled = true;
    view.videoApplyButton.disabled = true;
    view.bitrate.disabled = true;
  },

  enableControls(view) {
    view.audioDevices.disabled = false;
    view.videoDevices.disabled = false;
    view.echoCancellation.disabled = false;
    view.autoGainControl.disabled = false;
    view.noiseSuppression.disabled = false;
    view.width.disabled = false;
    view.height.disabled = false;
    view.fps.disabled = false;
    view.audioApplyButton.disabled = false;
    view.videoApplyButton.disabled = false;
    view.bitrate.disabled = false;
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
    view.button.innerText = "Stop streaming";
    view.button.onclick = function () {
      view.stopStreaming(view);
    };

    view.disableControls(view);

    view.pc = new RTCPeerConnection();

    // handle local events
    view.pc.onicecandidate = (ev) => {
      view.pushEventTo(view.el, "ice", JSON.stringify(ev.candidate));
    };

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

    view.pushEventTo(view.el, "offer", offer);
  },

  stopStreaming(view) {
    view.button.innerText = "Start Streaming";
    view.button.onclick = function () {
      view.startStreaming(view);
    };

    if (view.pc) {
      view.pc.close();
      view.pc = undefined;
    }

    view.enableControls(view);
  },
};
