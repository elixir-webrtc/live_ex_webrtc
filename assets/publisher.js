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

      view.audioApplyButton = document.getElementById("lex-audio-apply-button");
      view.videoApplyButton = document.getElementById("lex-video-apply-button");
      view.button = document.getElementById("lex-button");

      view.audioDevices.onchange = function () {
        view.setupStream(view);
      };

      view.videoDevices.onchange = function () {
        view.setupStream(view);
      };

      view.audioApplyButton.onclick = function () {
        view.setupStream(view);
      };

      view.videoApplyButton.onclick = function () {
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
          view.audioApplyButton.disabled = false;
          view.videoApplyButton.disabled = false;
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
      view.audioApplyButton.disabled = true;
      view.videoApplyButton.disabled = true;
      view.bitrate.disabled = true;
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
      view.audioApplyButton.disabled = false;
      view.videoApplyButton.disabled = false;
      view.bitrate.disabled = false;
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
            let bitrate;

            stats.forEach((report) => {
              if (report.type === "outbound-rtp" && report.kind === "video") {
                if (!view.lastVideoReport) {
                  bitrate = (report.bytesSent * 8) / 1000;
                } else {
                  const timeDiff =
                    (report.timestamp - view.lastVideoReport.timestamp) / 1000;
                  if (timeDiff == 0) {
                    // this should never happen as we are getting stats every second
                    bitrate = 0;
                  } else {
                    bitrate =
                      ((report.bytesSent - view.lastVideoReport.bytesSent) *
                        8) /
                      timeDiff;
                  }
                }

                view.videoBitrate.innerText = (bitrate / 1000).toFixed();
                view.lastVideoReport = report;
              } else if (
                report.type === "outbound-rtp" &&
                report.kind === "audio"
              ) {
                if (!view.lastAudioReport) {
                  bitrate = report.bytesSent;
                } else {
                  const timeDiff =
                    (report.timestamp - view.lastAudioReport.timestamp) / 1000;
                  if (timeDiff == 0) {
                    // this should never happen as we are getting stats every second
                    bitrate = 0;
                  } else {
                    bitrate =
                      ((report.bytesSent - view.lastAudioReport.bytesSent) *
                        8) /
                      timeDiff;
                  }
                }

                view.audioBitrate.innerText = (bitrate / 1000).toFixed();
                view.lastAudioReport = report;
              }
            });

            // calculate packet loss
            if (!view.lastAudioReport || !view.lastVideoReport) {
              view.packetLoss.innerText = 0;
            } else {
              const packetsSent =
                view.lastVideoReport.packetsSent +
                view.lastAudioReport.packetsSent;
              const rtxPacketsSent =
                view.lastVideoReport.retransmittedPacketsSent +
                view.lastAudioReport.retransmittedPacketsSent;
              const nackReceived =
                view.lastVideoReport.nackCount + view.lastAudioReport.nackCount;

              if (nackReceived == 0) {
                view.packetLoss.innerText = 0;
              } else {
                view.packetLoss.innerText = (
                  (nackReceived / (packetsSent - rtxPacketsSent)) *
                  100
                ).toFixed();
              }
            }
          }, 1000);
        } else if (view.pc.connectionState === "failed") {
          view.pushEvent("stop-streaming", {reason: "failed"})
          view.stopStreaming(view);
        }
      };

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
