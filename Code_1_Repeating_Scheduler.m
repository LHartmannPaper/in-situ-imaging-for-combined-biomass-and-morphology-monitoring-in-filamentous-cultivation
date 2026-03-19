%% REPEATING SCHEDULER – runs the capture+analysis script on a fixed cadence
%
%   Repeats an "acquire-and-pre-analyze" cycle forever. Each cycle calls your
%   main script once, then waits so that cycles start every
%   1800 seconds (30 minutes).
%
% Inputs:
%   - Secondary script name that is to be executed
%
% Outputs:
%   - Console logs for starts/errors and the wait time until next cycle.
%  
% Step 1:   reset console, variables, and figures ; start an infinite loop: this scheduler never exits by itself
clc; clear all, close all; 
while true

    tic; % Step 2: start a stopwatch to measure the duration of one full cycle

    try
        % Step 3: log a readable start time for this cycle
        fprintf("Starting new acquisition cycle at %s\n", datestr(now, 'HH:MM:SS'));

        % Step 4: run your main capture + pre-analysis script
        %         Replace the placeholder below with the full path to your main script.
        run('C:\PATH\TO\YOUR\SCRIPT\Code_2_Image_Acquisition_Loop_2.m');   

    catch ME
        % Step 5: if anything fails inside the run() call, catch and print the error
        fprintf("Error during cycle: %s\n", ME.message);
    end

    % Step 6: compute how long this cycle took, in seconds
    elapsed   = toc;                  % seconds since the tic above
    remaining = 1800 - elapsed;       % target cadence is 1800 s; compute how much time is left until next start

    % Step 7: either sleep the remaining time or immediately start next cycle
    if remaining > 0
        fprintf("Waiting %.1f seconds until the next cycle...\n", remaining);
        pause(remaining);             % pause makes this thread sleep without CPU load
    else
        fprintf("Processing exceeded the target cadence. Restarting immediately.\n");
    end
end