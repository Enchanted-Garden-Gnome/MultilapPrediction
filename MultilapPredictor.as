array<int> lapTimes;
array<array<int>> checkpointTimesPerLap;  // [lap][checkpoint] = time from lap start
uint previousLandmarkIndex = uint(-1);
bool isMultilap = false;
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
bool editMode = false;

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

// Load font on plugin initialization
void Main() {
    predFont = nvg::LoadFont("Oswald-Regular.ttf");
    print("Font loaded: " + predFont);
}

// Track lap progress and calculate predictions
void Update(float dt) {
    Update_Retire();
    
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
    
    if (player.ScriptAPI is null) {
        Reset();
        return;
    }
    
    if (player.CurrentLaunchedRespawnLandmarkIndex == uint(-1)) {
        Reset();
        return;
    }
    
    totalLaps = playground.Map.TMObjective_IsLapRace ? playground.Map.TMObjective_NbLaps : 1;
    isMultilap = totalLaps > 1;
    
    if (!isMultilap) return;
    
    auto scriptPlayer = cast<CSmScriptPlayer>(player.ScriptAPI);
    if (scriptPlayer is null) return;
    
    if (!lapActive) {
        lapStartTime = GetRaceTime(scriptPlayer);
        lapActive = true;
        currentLap = 0;
    }
    
    MwFastBuffer<CGameScriptMapLandmark@> landmarks = playground.Arena.MapLandmarks;
    uint landmarkIndex = player.CurrentLaunchedRespawnLandmarkIndex;
    
    // Track when player hits a new checkpoint or finish
    if (previousLandmarkIndex != landmarkIndex && landmarkIndex < landmarks.Length) {
        auto landmark = landmarks[landmarkIndex];
        
        if (landmark.Waypoint !is null) {
            int64 currentTime = GetRaceTime(scriptPlayer);
            int cpTime = int(currentTime - lapStartTime);
            currentLapCheckpoints.InsertLast(cpTime);
            
            if (landmark.Waypoint.IsFinish || landmark.Waypoint.IsMultiLap) {
                int lapTime = int(currentTime - lapStartTime);
                
                if (lapTime > 0) {
                    lapTimes.InsertLast(lapTime);
                    checkpointTimesPerLap.InsertLast(currentLapCheckpoints);
                    currentLap++;
                    print("Lap " + currentLap + " completed: " + Time::Format(lapTime));
                    
                    currentLapCheckpoints.RemoveRange(0, currentLapCheckpoints.Length);
                    lapStartTime = currentTime;
                } else {
                    Reset();
                }
            }
            
            predictedTime = CalculatePredictedTime();

            if (currentLap >= 1 && (showEveryCheckpoint || landmark.Waypoint.IsFinish || landmark.Waypoint.IsMultiLap)) {
                showTime = Time::Now;
                
            }
        }
        
        if (landmark.Waypoint is null) {
            Reset();
        }
        
        previousLandmarkIndex = landmarkIndex;
    }
}

// Clear all lap data when leaving a race or respawning
void Reset() {
    lapTimes.RemoveRange(0, lapTimes.Length);
    checkpointTimesPerLap.RemoveRange(0, checkpointTimesPerLap.Length);
    currentLapCheckpoints.RemoveRange(0, currentLapCheckpoints.Length);
    previousLandmarkIndex = uint(-1);
    currentLap = 0;
    isMultilap = false;
    lapActive = false;
    predictedTime = 0;
}

// Display the prediction UI with drag support
void Render() {
    if (!showPredictor) return;
    
    if (!UI::IsGameUIVisible()) return;
    
    bool visible = Time::Now < showTime + 3000 || isDragging || editMode;
    if (!visible) return;
    
    if (currentLap == 0 && !isDragging && !editMode) return;
    
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
    if (editMode && predictedTime <= 0) {
        text = Icons::FlagCheckered + " 123:45.678";
    } else {
        text = Icons::FlagCheckered + " " + Time::Format(predictedTime);
    }
    
    if (predFont != 0) {
        nvg::FontFace(predFont);
    }
    
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

// Calculate average lap time, excluding first lap to improve accuracy
int CalculateRunningAverageLapTime() {
    if (currentLap == 0) return 0;
    
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
    if (currentLap == 0) return 0;
    
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
    
    return count > 0 ? sum / count : 0;
}

// Predict final race time based on completed laps and checkpoint data
int CalculatePredictedTime() {
    if (currentLap == 0) return -1;
    
    if (player is null || player.ScriptAPI is null) return 0;
    
    auto scriptPlayer = cast<CSmScriptPlayer>(player.ScriptAPI);
    if (scriptPlayer is null) return 0;
    
    int64 raceTime = GetRaceTime(scriptPlayer);
    int currentLapTime = int(raceTime - lapStartTime);
    
    int completedTime = 0;
    for (uint i = 0; i < currentLap; i++) {
        completedTime += lapTimes[i];
    }
    
    int avgLapTime = CalculateRunningAverageLapTime();
    if (avgLapTime == 0) avgLapTime = lapTimes[lapTimes.Length - 1];
    
    int remainingCurrentLap = 0;
    
    if (currentLapCheckpoints.Length == 0) {
        // Start of lap: use full lap average
        remainingCurrentLap = avgLapTime;
    } else {
        // Mid-lap: use checkpoint history if available
        uint lastCheckpoint = currentLapCheckpoints.Length - 1;
        int avgRemainingFromCheckpoint = CalculateAverageTimeFromCheckpoint(lastCheckpoint);
        
        if (avgRemainingFromCheckpoint > 0) {
            remainingCurrentLap = avgRemainingFromCheckpoint;
        } else {
            int timeAtLastCp = currentLapCheckpoints[lastCheckpoint];
            remainingCurrentLap = avgLapTime - timeAtLastCp;
        }
    }
    
    int remainingFullLaps = totalLaps - currentLap - 1;
    
    return completedTime + currentLapTime + remainingCurrentLap + (avgLapTime * remainingFullLaps);
}

// Get current race time for online or solo mode
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

// Add menu item to toggle the predictor
void RenderMenu() {
    if (UI::MenuItem("\\$8f8" + Icons::ClockO + "\\$z Multilap Predictor", "", showPredictor)) {
        showPredictor = !showPredictor;
    }
}

// Detect when player retires/restarts
void Update_Retire() {
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
                print("Player retired/restarted");
                Reset();
            }
            if (retireHandled && post != CSmScriptPlayer::EPost::Char) {
                retireHandled = false;
            }
        }
    }
}