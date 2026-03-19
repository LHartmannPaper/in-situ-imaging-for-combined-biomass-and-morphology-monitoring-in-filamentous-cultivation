%% CAMERA CAPTURE + SHELLY-PLUG CONTROL (capture-only)
%
% Short summary:
%   Connect to the GenICam/GenTL camera, take a burst of images while a Shelly smart plug
%   powers the illumination, and store images into a dated folder structure as .bmp.
%
% Inputs:
%   - Camera interface: adapter "gentl", device #1, format "Mono8"
%   - Shelly IP: the local IP address of your Shelly Plug S
%   - numImages: how many images to acquire in this cycle
%   - Paths: base folder for saving images
%
% Outputs:
%   - A dated folder tree: PATH_TO_BASE_IMAGE_FOLDER\YYYYMMDD\zyklus_HHMMSS\bild_XX.bmp
%   - Console logs with acquisition progress
%
% Relationship to the other scripts:
%   - Called by the scheduler (code 1), every 30 minutes.


%% Step 1 – Configure the camera (GenTL, monochrome 8-bit)
clc; close all; clear;
v = videoinput("gentl", 1, "Mono8");           % create a Video Input object: GenTL adapter, device #1, 8-bit mono frames
src = getselectedsource(v);                    % get the device-specific source object to tweak camera properties
src.ContrastBrightLimit = 255;                 % set the device's brightness/contrast limit (property is camera-dependent)
src.ExposureTime = 1014.343;                   % exposure time in microseconds (device-specific units; here ~1.0 ms)
v.FramesPerTrigger = 1;                        % on each start(), capture exactly one frame
v.TriggerRepeat = 0;                           % do not auto-repeat; we will manually call start() per frame

%% Step 2 – Build a timestamped folder structure for this acquisition cycle
timestamp = datestr(now, 'yyyymmdd_HHMMSS');   % e.g., 20250605_141530
dateStr = timestamp(1:8);                      % e.g., YYYYMMDD
timeStr = timestamp(10:end);                   % e.g., HHMMSS

savedFolderBase = 'PATH_TO_BASE_IMAGE_FOLDER'; % top-level base under which daily/cycle folders are created
dayFolder = fullfile(savedFolderBase, dateStr);% day folder: PATH_TO_BASE_IMAGE_FOLDER\YYYYMMDD
savedFolder = fullfile(dayFolder, ['zyklus_' timeStr]); % cycle folder: ...\YYYYMMDD\zyklus_HHMMSS

if ~exist(savedFolder, 'dir')                  % ensure the cycle folder exists before saving images
    mkdir(savedFolder);
end
fprintf("Target folder: %s\n", savedFolder);

%% Step 3 – Acquisition settings and buffers
numImages = 30;                                % target number of images to acquire in this cycle
images = cell(1, numImages);                   % preallocate a cell array to hold raw frames
imageCount = 0;                                % will increment when a valid image is stored
attempts = 0;                                  % counts how many capture attempts were made (valid or invalid)
maxAttempts = 150;                             % safety cap to avoid infinite retries if images keep failing

%% Step 4 – Shelly Plug S configuration (local HTTP control)
shellyIP = 'XXX.XXX.XXX.XXX';                  % replace with the local IP of your Shelly Plug S
urlOn  = ['http://' shellyIP '/relay/0?turn=on'];   % HTTP GET to turn relay 0 ON
urlOff = ['http://' shellyIP '/relay/0?turn=off'];  % HTTP GET to turn relay 0 OFF

try
    %% Step 5 – Power-cycle the illumination before acquiring
    responseOff = webread(urlOff);             % ensure it is OFF first (optional consistency)
    responseOn  = webread(urlOn);              % turn ON; illumination should stabilize quickly
    pause(1);                                  % wait ~1 s for light to settle (avoid exposure flicker)

    %% Step 6 – Acquire until we have numImages or we reach maxAttempts
    while imageCount < numImages && attempts < maxAttempts
        start(v);                               % arm the camera for a single frame (FramesPerTrigger = 1)
        snapshot = getdata(v, 1);               % fetch the frame just captured (blocks until ready)
        attempts = attempts + 1;                % count this attempt regardless of success

        % Step 6.1 – Quick quality gate: reject frames whose last row is all zeros
        % Rationale: observed failure mode where a dead/bad frame shows a black bottom row.
        lastRow = snapshot(end, :);             % extract the bottom row of pixels
        if all(lastRow == 0)                    % if every pixel in that row is zero
            fprintf("Image rejected (black bottom row) – retrying...\n");
            continue;                           % do not store this image; loop to the next attempt
        end

        % Step 6.2 – Accept and buffer the image
        imageCount = imageCount + 1;            % advance the count of valid images
        images{imageCount} = snapshot;          % store the frame in RAM
        fprintf("Captured image %d/%d.\n", imageCount, numImages);
    end

    %% Step 7 – Turn the Shelly plug and its lighting OFF after acquisition
    responseOff = webread(urlOff);

catch ME
    % If HTTP requests or camera control fail, report the issue and continue.
    disp('Error while accessing the smart plug or during acquisition:');
    disp(ME.message);
end

%% Step 8 – Clean up the camera object
delete(v);                                     % release hardware resources
clear src v;                                   % remove objects from the workspace

%% Step 9 – Persist captured images to disk (BMP) inside the cycle folder
if imageCount == 0
    warning('No valid images were captured.');
else
    for idx = 1:imageCount                     % save only the successfully captured valid images
        img = images{idx};                     % pull the image from memory
        filename = fullfile(savedFolder, sprintf('bild_%02d.bmp', idx));  % bild_01.bmp, bild_02.bmp, ...
        imwrite(img, filename);                % write BMP to disk
        % Optional: additionally save as PNG (commented out)
        % imwrite(img, strrep(filename, '.bmp', '.png'));
    end
    fprintf("Done. %d images saved to: %s\n", imageCount, savedFolder);
end