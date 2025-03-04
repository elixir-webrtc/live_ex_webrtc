export function createPublisherHook(iceServers = []) {
  return {
    async mounted() {
      const view = this;

      view.handleEvent("start-streaming", () => view.startStreaming(view));
      view.handleEvent("stop-streaming", () => view.stopStreaming(view));

      view.audioDevices = document.getElementById("lex-audio-devices");
      view.videoDevices = document.getElementById("lex-video-devices");

      view.echoCancellation = document.getElementById("lex-echo-cancellation");
      view.autoGainControl = document.getElementById("lex-auto-gain-control");
      view.noiseSuppression = document.getElementById("lex-noise-suppression");

      view.width = document.getElementById("lex-width");
      view.height = document.getElementById("lex-height");
      view.fps = document.getElementById("lex-fps");
      view.bitrate = document.getElementById("lex-bitrate");

      view.recordStream = document.getElementById("lex-record-stream");

      view.previewPlayer = document.getElementById("lex-preview-player");

      view.audioBitrate = document.getElementById("lex-audio-bitrate");
      view.videoBitrate = document.getElementById("lex-video-bitrate");
      view.packetLoss = document.getElementById("lex-packet-loss");
      view.status = document.getElementById("lex-status");
      view.time = document.getElementById("lex-time");

      view.button = document.getElementById("lex-button");
      view.applyButton = document.getElementById("lex-apply-button");

      view.simulcast = document.getElementById("lex-simulcast");

      view.audioDevices.onchange = function () {
        view.setupStream(view);
      };

      view.videoDevices.onchange = function () {
        view.setupStream(view);
      };

      view.applyButton.onclick = function () {
        view.setupStream(view);
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
        await view.findDevices(view);
        try {
          await view.setupStream(view);
          view.button.disabled = false;
          view.applyButton.disabled = false;
        } catch (error) {
          console.error("Couldn't setup stream, reason:", error.stack);
        }
      } catch (error) {
        console.error(
          "Couldn't find audio and/or video devices, reason: ",
          error.stack
        );
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
      view.bitrate.disabled = true;
      view.simulcast.disabled = true;
      view.applyButton.disabled = true;
      // Button present only when Recorder is used
      if (view.recordStream) view.recordStream.disabled = true;
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
      view.bitrate.disabled = false;
      view.simulcast.disabled = false;
      view.applyButton.disabled = false;
      // See above
      if (view.recordStream) view.recordStream.disabled = false;
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
          view.videoDevices.options[view.videoDevices.options.length] =
            new Option(device.label, device.deviceId);
        } else if (device.kind === "audioinput") {
          view.audioDevices.options[view.audioDevices.options.length] =
            new Option(device.label, device.deviceId);
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
      view.disableControls(view);

      view.pc = new RTCPeerConnection({ iceServers: iceServers });

      // handle local events
      view.pc.onconnectionstatechange = () => {
        if (view.pc.connectionState === "connected") {
          view.startTime = new Date();
          view.status.classList.remove("bg-red-500");
          // TODO use tailwind
          view.status.style.backgroundColor = "rgb(34, 197, 94)";

          view.statsIntervalId = setInterval(async function () {
            if (!view.pc) {
              clearInterval(view.statsIntervalId);
              view.statsIntervalId = undefined;
              return;
            }

            view.time.innerText = view.toHHMMSS(new Date() - view.startTime);

            const stats = await view.pc.getStats(null);
            view.processStats(view, stats);
          }, 1000);
        } else if (view.pc.connectionState === "failed") {
          view.pushEvent("stop-streaming", { reason: "failed" });
          view.stopStreaming(view);
        }
      };

      view.pc.onicecandidate = (ev) => {
        view.pushEventTo(view.el, "ice", JSON.stringify(ev.candidate));
      };

      view.pc.addTrack(view.localStream.getAudioTracks()[0], view.localStream);

      if (view.simulcast.checked === true) {
        view.addSimulcastVideo(view);
      } else {
        view.addNormalVideo(view);
      }

      const offer = await view.pc.createOffer();
      await view.pc.setLocalDescription(offer);

      view.pushEventTo(view.el, "offer", offer);
    },

    processStats(view, stats) {
      let videoBytesSent = 0;
      let videoPacketsSent = 0;
      let videoNack = 0;
      let audioBytesSent = 0;
      let audioPacketsSent = 0;
      let audioNack = 0;

      let statsTimestamp;
      stats.forEach((report) => {
        if (!statsTimestamp) statsTimestamp = report.timestamp;

        if (report.type === "outbound-rtp" && report.kind === "video") {
          videoBytesSent += report.bytesSent;
          videoPacketsSent += report.packetsSent;
          videoNack += report.nackCount;
        } else if (report.type === "outbound-rtp" && report.kind === "audio") {
          audioBytesSent += report.bytesSent;
          audioPacketsSent += report.packetsSent;
          audioNack += report.nackCount;
        }
      });

      const timeDiff = (statsTimestamp - view.lastStatsTimestamp) / 1000;

      let bitrate;

      if (!view.lastVideoBytesSent) {
        bitrate = (videoBytesSent * 8) / 1000;
      } else {
        if (timeDiff == 0) {
          // this should never happen as we are getting stats every second
          bitrate = 0;
        } else {
          bitrate = ((videoBytesSent - view.lastVideoBytesSent) * 8) / timeDiff;
        }
      }

      view.videoBitrate.innerText = (bitrate / 1000).toFixed();

      if (!view.lastAudioBytesSent) {
        bitrate = (audioBytesSent * 8) / 1000;
      } else {
        if (timeDiff == 0) {
          // this should never happen as we are getting stats every second
          bitrate = 0;
        } else {
          bitrate = ((audioBytesSent - view.lastAudioBytesSent) * 8) / timeDiff;
        }
      }

      view.audioBitrate.innerText = (bitrate / 1000).toFixed();

      // calculate packet loss
      if (!view.lastAudioPacketsSent || !view.lastVideoPacketsSent) {
        view.packetLoss.innerText = 0;
      } else {
        const packetsSent =
          videoPacketsSent +
          audioPacketsSent -
          view.lastAudioPacketsSent -
          view.lastVideoPacketsSent;

        const nack =
          videoNack + audioNack - view.lastVideoNack - view.lastAudioNack;

        if (packetsSent == 0 || timeDiff == 0) {
          view.packetLoss.innerText = 0;
        } else {
          view.packetLoss.innerText = (
            ((nack / packetsSent) * 100) /
            timeDiff
          ).toFixed(2);
        }
      }

      view.lastVideoBytesSent = videoBytesSent;
      view.lastVideoPacketsSent = videoPacketsSent;
      view.lastVideoNack = videoNack;
      view.lastAudioBytesSent = audioBytesSent;
      view.lastAudioPacketsSent = audioPacketsSent;
      view.lastAudioNack = audioNack;
      view.lastStatsTimestamp = statsTimestamp;
    },

    addSimulcastVideo(view) {
      const videoTrack = view.localStream.getVideoTracks()[0];
      const settings = videoTrack.getSettings();
      const maxTotalBitrate = view.bitrate.value * 1024;

      // This is based on:
      // https://source.chromium.org/chromium/chromium/src/+/main:third_party/webrtc/video/config/simulcast.cc;l=79?q=simulcast.cc
      let sendEncodings;
      if (settings.width >= 960 && settings.height >= 540) {
        // we do a very simple calculation: maxTotalBitrate = x + 1/4x + 1/16x
        // x - bitrate for base resolution
        // 1/4x- bitrate for resolution scaled down by 2 - we decrese total number of pixels by 4 (width/2*height/2)
        // 1/16x- bitrate for resolution scaled down by 4 - we decrese total number of pixels by 16 (width/4*height/4)
        const maxHBitrate = Math.floor((16 * maxTotalBitrate) / 21);
        const maxMBitrate = Math.floor(maxHBitrate / 4);
        const maxLBitrate = Math.floor(maxHBitrate / 16);
        sendEncodings = [
          { rid: "h", maxBitrate: maxHBitrate },
          { rid: "m", scaleResolutionDownBy: 2, maxBitrate: maxMBitrate },
          { rid: "l", scaleResolutionDownBy: 4, maxBitrate: maxLBitrate },
        ];
      } else if (settings.width >= 480 && settings.height >= 270) {
        // maxTotalBitate = x + 1/4x
        const maxHBitrate = Math.floor((4 * maxTotalBitrate) / 5);
        const maxMBitrate = Math.floor(maxHBitrate / 4);
        sendEncodings = [
          { rid: "h", maxBitrate: maxHBitrate },
          { rid: "m", scaleResolutionDownBy: 2, maxBitrate: maxMBitrate },
        ];
      } else {
        sendEncodings = [{ rid: "h", maxBitrate: maxTotalBitrate }];
      }

      view.pc.addTransceiver(view.localStream.getVideoTracks()[0], {
        streams: [view.localStream],
        sendEncodings: sendEncodings,
      });
    },

    addNormalVideo(view) {
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
    },

    stopStreaming(view) {
      if (view.pc) {
        view.pc.close();
        view.pc = undefined;
      }

      view.resetStats(view);

      view.enableControls(view);
    },

    resetStats(view) {
      view.startTime = undefined;
      view.lastAudioReport = undefined;
      view.lastVideoReport = undefined;
      view.lastVideoBytesSent = 0;
      view.lastVideoPacketsSent = 0;
      view.lastVideoNack = 0;
      view.lastAudioBytesSent = 0;
      view.lastAudioPacketsSent = 0;
      view.lastAudioNack = 0;
      view.audioBitrate.innerText = 0;
      view.videoBitrate.innerText = 0;
      view.packetLoss.innerText = 0;
      view.time.innerText = "00:00:00";
      view.status.style.backgroundColor = "rgb(239, 68, 68)";
    },

    toHHMMSS(milliseconds) {
      // Calculate hours
      let hours = Math.floor(milliseconds / (1000 * 60 * 60));
      // Calculate minutes, subtracting the hours part
      let minutes = Math.floor((milliseconds % (1000 * 60 * 60)) / (1000 * 60));
      // Calculate seconds, subtracting the hours and minutes parts
      let seconds = Math.floor((milliseconds % (1000 * 60)) / 1000);

      // Formatting each unit to always have at least two digits
      hours = hours < 10 ? "0" + hours : hours;
      minutes = minutes < 10 ? "0" + minutes : minutes;
      seconds = seconds < 10 ? "0" + seconds : seconds;

      return hours + ":" + minutes + ":" + seconds;
    },
  };
}
