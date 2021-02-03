%% Ear calibration following probe calibration
[FileName,PathName,FilterIndex] = uigetfile('Calib*RME*.mat',...
    'Please pick PROBE CALIBRATION file to use');
probefile = fullfile(PathName, FileName);
load(probefile);

% Initializing RME
InitializePsychSound(1);
% Open device in duplex mode (3), with full device control (2)
% Use 2 output channels and 1 input channel at sampling rate of Fs.
devices = PsychPortAudio('GetDevices');
deviceindex = [];
for k = 1:numel(devices)
    if strcmp(devices(k).DeviceName, 'ASIO Fireface USB')
        deviceindex = devices(k).DeviceIndex;
    end
end

Fs = calib.SamplingRate * 1000;
driver = calib.driver;
pahandle = PsychPortAudio('Open', deviceindex, 3, 2, Fs, [2, 1], calib.BufferSize, [], [0, 1; 8 0]);
% Allocate input Buffer Size
PsychPortAudio('GetAudioData', pahandle, calib.BufferSize * 1/Fs);

%% Get subject and ear info
subj = input('Please subject ID:', 's');
earflag = 1;
while earflag == 1
    ear = input('Please enter which year (L or R):', 's');
    switch ear
        case {'L', 'R', 'l', 'r', 'Left', 'Right', 'left', 'right', 'LEFT', 'RIGHT'}
            earname = strcat('Ear-', upper(ear(1)));
            earflag = 0;
        otherwise
            fprintf(2, 'Unrecognized ear type! Try again!');
    end
end
calib.subj = subj;
calib.ear = ear;

% Make linear chirp upto nyquist
vo = calib.vo;
buffdata = zeros(2, calib.BufferSize);
buffdata(driver, :) = vo; % The other source plays nothing

% Check for clipping and load to buffer
if(any(abs(buffdata(1, :)) > 1))
    error('What did you do!? Sound is clipping!! Cannot Continue!!\n');
end

% Fill the audio playback buffer with the audio data 'wavedata':
PsychPortAudio('FillBuffer', pahandle, buffdata);

playrecTrigger = 1;
resplength = numel(vo); % How many samples to read from OAE buffer

%% Set attenuation and play
drop = db2mag(-1 * calib.Attenuation);
PsychPortAudio('Volume', pahandle, drop);

vins_ear = zeros(calib.Averages, calib.BufferSize);
for n = 1: (calib.Averages + calib.ThrowAway)
    %Start playing from the buffer:
    % 1 Repetition (repeat handled in this script rather than
    % PsychPortAudio)
    startTime = PsychPortAudio('Start', pahandle, 1);
    WaitSecs(calib.BufferSize * 1/Fs);
    % Stop playback:
    PsychPortAudio('Stop', pahandle);
    vin = PsychPortAudio('GetAudioData', pahandle);
    %Accumluate the time waveform - no artifact rejection
    if (n > calib.ThrowAway)
        vins_ear(n, :) = vin;
    end
end
energy = squeeze(sum(vins_ear.^2, 2));
good = (energy < median(energy) + 2*mad(energy)) & (energy > median(energy) - 2*mad(energy)) ;
vavg = squeeze(mean(vins_ear(good, :), 1));
Vavg = rfft(vavg)';

% Apply calibartions to convert voltage to pressure
% For ER-10X, this is approximate
mic_sens = 50e-3; % mV/Pa. TO DO: change after calibration
mic_gain = db2mag(40);
P_ref = 20e-6;
DR_onesided = 1;
mic_output_V = Vavg / (DR_onesided * mic_gain);
output_Pa = mic_output_V/mic_sens;
outut_Pa_20uPa_per_Vpp = output_Pa / P_ref; % unit: 20 uPa / Vpeak-peak

freq = 1000*linspace(0,calib.SamplingRate/2,length(Vavg))';
calib.vins_ear = vins_ear;

% Note no attenuation gives 4.75 V peak for the chirp
Vo = rfft(calib.vo) * 4.75 * db2mag(-1 * calib.Attenuation);

calib.EarRespH =  outut_Pa_20uPa_per_Vpp ./ Vo; %save for later


PsychPortAudio('Close', pahandle);

%% Plot data
figure(1);
ax(1) = subplot(2, 1, 1);
semilogx(calib.freq, db(abs(calib.EarRespH)), 'linew', 2);
ylabel('Response (dB re: 20 \mu Pa / V_{peak})', 'FontSize', 16);
ax(2) = subplot(2, 1, 2);
semilogx(calib.freq, unwrap(angle(calib.EarRespH), [], 1), 'linew', 2);
xlabel('Frequency (Hz)', 'FontSize', 16);
ylabel('Phase (rad)', 'FontSize', 16);
linkaxes(ax, 'x');
legend('show');
xlim([100, 24e3]);


%% Calculate Ear properties
calib = findHalfWaveRes(calib);
calib.Zec = ldimp(calib.Zs, calib.Ps, calib.EarRespH);
% decompose pressures
calib.fwb = 0.375;% %bandwidth/Nyquist freq
% Below crashes because tube impedance is not known
% [calib.Rec,calib.Rs,calib.Rx,calib.Pfor,calib.Prev,calib.Pinc,calib.Px] = decompose(calib.Zec,calib.Zs,calib.EarRespH,calib.Ps,calib.fwb);

%% Save calib
fname = strcat('Calib_',calib.drivername,calib.device,'_',subj,earname,'_',date, '_RME.mat');
save(fname,'calib');

% just before the subject arrives