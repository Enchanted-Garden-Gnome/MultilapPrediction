array<int> lapTimes;
array<array<int>> checkpointTimesPerLap;  // [lap][checkpoint] = time from lap start
uint previousLandmarkIndex = uint(-1);
uint totalLaps = 0;
uint currentLap = 0;
uint64 lapStartTime = 0;
bool lapActive = false;
uint64 showTime = 0;
string currentMapUid = "";
int checkpointDelta = 0;
array<int> currentLapCheckpoints;
int predictedTime = 0;

bool retireHandled = false;

CSmArenaClient@ playground = null;
CSmPlayer@ player = null;

bool isDragging = false;
vec2 dragOffset;
vec2 boxPosition;
vec2 boxSize;

[Setting name="Show predictor" category="Display"]
bool showPredictor = true;

[Setting name="Edit mode (always show for positioning)" category="Display"]
bool dragMode = false;

[Setting name="UI Scale" min=0.5 max=2 category="Display"]
float uiScale = 1.0;

[Setting name="Anchor X position" min=0 max=1 category="Display"]
float anchorX = 0.5;

[Setting name="Anchor Y position" min=0 max=1 category="Display"]
float anchorY = 0.25;

[Setting name="Font size" min=20 max=60 category="Display"]
int predFontSize = 24;

[Setting color name="Prediction text colour" category="Display"]
vec4 predTextColour = vec4(1, 1, 1, 1);

[Setting color name="Background colour" category="Display"]
vec4 predBgColour = vec4(0, 0, 0, 0.867);

[Setting name="Show text shadow" category="Display"]
bool predTextShadow = true;

[Setting name="Show at every checkpoint" category="Display"]
bool showEveryCheckpoint = true;


nvg::Font predFont;
void Main() {
    predFont = nvg::LoadFont("Oswald-Regular.ttf");
}

// Detect when player retires, taken from Split Speeds
void CheckRetire() {
    auto app = GetApp();
    auto map = app.RootMap;
    if (map is null) return;
    
    auto playground = app.CurrentPlayground;
    if (playground !is null && playground.GameTerminals.Length > 0) {
        auto terminal = playground.GameTerminals[0];
        auto gui_player = cast<CSmPlayer>(terminal.GUIPlayer);
        if (gui_player !is null && gui_player.ScriptAPI !is null) {
            auto post = (cast<CSmScriptPlayer>(gui_player.ScriptAPI)).Post;
            if (!retireHandled && post == CSmScriptPlayer::EPost::Char) {
                retireHandled = true;
                Reset();
            }
            if (retireHandled && post != CSmScriptPlayer::EPost::Char) {
                retireHandled = false;
            }
        }
    }
}

// Clear all lap data when leaving a race or respawning
void Reset() {
    lapTimes.RemoveRange(0, lapTimes.Length);
    checkpointTimesPerLap.RemoveRange(0, checkpointTimesPerLap.Length);
    currentLapCheckpoints.RemoveRange(0, currentLapCheckpoints.Length);
    previousLandmarkIndex = uint(-1);
    currentLap = 0;
    lapActive = false;
    predictedTime = 0;
}

void Update(float dt) {
    CheckRetire();
    @playground = cast<CSmArenaClient>(GetApp().CurrentPlayground);
    
    if (playground is null 
        || playground.Arena is null 
        || playground.Map is null 
        || playground.GameTerminals.Length <= 0
        || playground.GameTerminals[0].UISequence_Current != CGamePlaygroundUIConfig::EUISequence::Playing
        || cast<CSmPlayer>(playground.GameTerminals[0].GUIPlayer) is null) {
        Reset();
        return;
    }

    @player = cast<CSmPlayer>(playground.GameTerminals[0].GUIPlayer);
    auto scriptPlayer = cast<CSmScriptPlayer>(player.ScriptAPI);
    
    int64 timeThisFrame = GetRaceTime(scriptPlayer);

    if (scriptPlayer is null) {
        Reset();
        return;
    }

    if (!playground.Map.TMObjective_IsLapRace) {
        Reset();
        return;
    }

    totalLaps = playground.Map.TMObjective_NbLaps;

    if (totalLaps <= 1) {
        Reset();
        return;
    }
    
    if (!lapActive) {
        lapStartTime = timeThisFrame;
        lapActive = true;
        currentLap = 0;
    }

    MwFastBuffer<CGameScriptMapLandmark@> landmarks = playground.Arena.MapLandmarks;
    uint landmarkIndex = player.CurrentLaunchedRespawnLandmarkIndex;
    if (landmarkIndex == -1) {
        Reset();
        return;
    }

    // Track when player hits a new checkpoint or finish
    if (previousLandmarkIndex != landmarkIndex) {
        auto landmark = landmarks[landmarkIndex];
        
        if (landmark.Waypoint !is null) {
            int cpTime = int(timeThisFrame - lapStartTime);
            currentLapCheckpoints.InsertLast(cpTime);
            
            if (landmark.Waypoint.IsFinish || landmark.Waypoint.IsMultiLap) {
                int lapTime = int(timeThisFrame - lapStartTime);
                
                // if we hit a new lap and the time is not 0 then we hit the next lap
                if (lapTime > 0) {
                    lapTimes.InsertLast(lapTime);
                    checkpointTimesPerLap.InsertLast(currentLapCheckpoints);
                    currentLap += 1;                    
                    currentLapCheckpoints.RemoveRange(0, currentLapCheckpoints.Length);
                    lapStartTime = timeThisFrame;
                } else {
                    // otherwise we are starting lap 0
                    Reset();
                }
            }
            
            predictedTime = CalculatePredictedTime(timeThisFrame);

            if (currentLap >= 1 && (showEveryCheckpoint || landmark.Waypoint.IsFinish || landmark.Waypoint.IsMultiLap)) {
                // setting time to now activate the render display for 3 seconds
                showTime = Time::Now;
                
            }
        }
        
        // if (landmark.Waypoint is null) {
        //     Reset();
        // }
        
        previousLandmarkIndex = landmarkIndex;
    }
}

// Get current timer time in race. Taken from copium timer plugin
int64 GetRaceTime(CSmScriptPlayer@ scriptPlayer) {
    if (scriptPlayer is null)
        return 0;
    
    auto playgroundScript = cast<CSmArenaRulesMode>(GetApp().PlaygroundScript);
    
    // Online vs solo mode require different time sources
    if (playgroundScript is null)
        return GetApp().Network.PlaygroundClientScriptAPI.GameTime - scriptPlayer.StartTime;
    else
        return playgroundScript.Now - scriptPlayer.StartTime;
}

// Calculate average lap time, excluding first lap to improve accuracy
int CalculateAverageLapTime() {
    
    if (currentLap == 1) {
        return lapTimes[0];
    }
    
    // Skip first lap and average the rest
    int sum = 0;
    for (uint i = 1; i < currentLap; i++) {
        sum += lapTimes[i];
    }
    
    return sum / (currentLap - 1);
}

// Calculate average time remaining from a specific checkpoint to lap end
int CalculateAverageTimeFromCheckpoint(uint checkpointIndex) {
    
    int sum = 0;
    int count = 0;
    
    // Include lap 1 data only when on lap 2
    uint startLap = currentLap == 1 ? 0 : 1;
    
    for (uint lap = startLap; lap < currentLap; lap++) {
        if (checkpointIndex < checkpointTimesPerLap[lap].Length) {
            int timeAtCheckpoint = checkpointTimesPerLap[lap][checkpointIndex];
            int lapTime = lapTimes[lap];
            int remainingTime = lapTime - timeAtCheckpoint;
            sum += remainingTime;
            count++;
        }
    }
    
    return sum / count;
}

// Predict final race time based on completed laps and checkpoint data
int CalculatePredictedTime(int64 raceTime) {
    if (currentLap == 0) return -1;
    
    int avgLapTime = CalculateAverageLapTime();
    int remainingFullLaps = totalLaps - currentLap - 1;
    
    int remainingCurrentLap = 0;
    
    if (currentLapCheckpoints.Length == 0) {
        // Start of lap: use full lap average
        return raceTime + avgLapTime * (remainingFullLaps + 1);
    } else {
        // Mid-lap: use checkpoint history if available
        uint lastCheckpoint = currentLapCheckpoints.Length - 1;
        int avgRemainingFromCheckpoint = CalculateAverageTimeFromCheckpoint(lastCheckpoint);
        remainingCurrentLap = avgRemainingFromCheckpoint;
        return raceTime + remainingCurrentLap + (avgLapTime * remainingFullLaps);
    }
}

void RenderMenu() {
    if (UI::MenuItem("\\$8f8" + Icons::ClockO + "\\$z Multilap Predictor", "", showPredictor)) {
        showPredictor = !showPredictor;
    }
}

// Display the prediction UI with drag support
void Render() {
    if (!showPredictor) return;
    
    if (!UI::IsGameUIVisible()) return;
    
    bool visible = Time::Now < showTime + 3000 || isDragging || dragMode;
    if (!visible) return;
    
    if (currentLap == 0 && !isDragging && !dragMode) return;
    
    HandleDragging();
    
    
    RenderPrediction();
}

// Allow dragging the prediction box to reposition it
void HandleDragging() {
    auto mousePos = UI::GetMousePos();
    bool leftMouseDown = UI::IsMouseDown(UI::MouseButton::Left);
    
    bool isMouseOver = mousePos.x >= boxPosition.x && mousePos.x <= boxPosition.x + boxSize.x &&
                       mousePos.y >= boxPosition.y && mousePos.y <= boxPosition.y + boxSize.y;
    
    if (isMouseOver && leftMouseDown && !isDragging) {
        isDragging = true;
        dragOffset = vec2(mousePos.x - boxPosition.x, mousePos.y - boxPosition.y);
        showTime = Time::Now;
    } else if (isDragging && leftMouseDown) {
        float newX = mousePos.x - dragOffset.x + boxSize.x / 2;
        float newY = mousePos.y - dragOffset.y + boxSize.y / 2;
        
        anchorX = newX / 1920.0;
        anchorY = newY / 1080.0;
        
        anchorX = Math::Clamp(anchorX, 0.0, 1.0);
        anchorY = Math::Clamp(anchorY, 0.0, 1.0);
        
        showTime = Time::Now;
    } else if (isDragging && !leftMouseDown) {
        isDragging = false;
    }
}

// Draw the prediction box with time and styling
void RenderPrediction() {
    
    string text;
    if (dragMode) {
        text = Icons::FlagCheckered + " 123:45.678";
    } else {
        text = Icons::FlagCheckered + " " + Time::Format(predictedTime);
    }
    

    nvg::FontFace(predFont);
    
    float fontSize = predFontSize * uiScale;
    nvg::FontSize(fontSize);
    
    vec2 textBounds = nvg::TextBounds(text);
    float boxWidth = textBounds.x + 10 * uiScale;
    float boxHeight = textBounds.y + 10 * uiScale;
    
    float x = anchorX * 1920;
    float y = anchorY * 1080;
    
    boxPosition = vec2(x - boxWidth / 2, y - boxHeight / 2);
    boxSize = vec2(boxWidth, boxHeight);
    
    nvg::BeginPath();
    nvg::Rect(boxPosition.x, boxPosition.y, boxWidth, boxHeight);
    if (isDragging) {
        nvg::FillColor(vec4(predBgColour.x, predBgColour.y, predBgColour.z, 0.95));
    } else {
        nvg::FillColor(predBgColour);
    }
    nvg::Fill();
    nvg::ClosePath();
    
    nvg::TextAlign(nvg::Align::Center | nvg::Align::Middle);
    
    if (predTextShadow) {
        nvg::FillColor(vec4(0, 0, 0, 0.6));
        nvg::Text(x + 1, y + 1, text);
    }
    
    nvg::FillColor(predTextColour);
    nvg::Text(x, y, text);
}