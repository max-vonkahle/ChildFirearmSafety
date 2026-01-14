# Loading Screen Design for Safety Training

## Overview
The goal is to replace the camera feed with a loading screen when the Safety Training scene starts. This loading screen will be displayed while the system configures the assets in the correct places based on the room. Once the assets are configured, the screen will transition to the camera feed and prompt the user to press anywhere on the screen to begin the training.

## Current Implementation Analysis
1. **Safety Training Scene**: The Safety Training scene is initiated in `OrchestratorView.swift`. When a room is selected, the `ARSceneView` is displayed, and the `handleSceneAppear` function is called to load the world map and start the session.

2. **Camera Feed Initialization**: The camera feed is initialized in `ARViewContainer.swift` within the `makeUIView` function. The `ARView` is created and configured with the `ARWorldTrackingConfiguration`.

3. **Asset Configuration**: Assets are configured and placed in the scene through the `ARCoordinator.swift` file. The `loadWorldMap` function is called to load the saved room configuration, and the `session(_:didAdd:)` function is triggered to place the assets in the scene.

## Proposed Design

### Loading Screen
- **Content**: The loading screen will display a simple message such as "Loading your training environment..." along with a progress indicator (e.g., a spinning activity indicator).
- **Appearance**: The loading screen will cover the entire screen and will be displayed on top of the `ARSceneView`.
- **Behavior**: The loading screen will be displayed until the assets are fully configured and placed in the scene.

### Transition to Camera Feed
- **Trigger**: Once the assets are configured and placed, the loading screen will fade out, revealing the camera feed.
- **Prompt**: After the transition, a prompt will appear on the screen, instructing the user to press anywhere to begin the training.

### User Interaction
- **Tap Gesture**: The user can tap anywhere on the screen to dismiss the prompt and begin the training. This will trigger the start of the training session.

## Implementation Steps

### 1. Create a Loading Screen View
Create a new SwiftUI view for the loading screen. This view will include:
- A background to cover the entire screen.
- A loading message.
- A progress indicator.

### 2. Modify `OrchestratorView`
- Add a state variable to track whether the assets are loaded.
- Display the loading screen when the scene appears and hide it once the assets are loaded.
- Add a prompt view that appears after the assets are loaded.

### 3. Update `ARCoordinator`
- Add a notification or callback to signal when the assets are fully configured and placed in the scene.

### 4. Add Tap Gesture Handling
- Implement a tap gesture handler to dismiss the prompt and start the training session.

## Mermaid Diagram

```mermaid
graph TD
    A[Start Safety Training Scene] --> B[Show Loading Screen]
    B --> C[Load World Map and Configure Assets]
    C --> D{Assets Configured?}
    D -->|No| C
    D -->|Yes| E[Hide Loading Screen]
    E --> F[Show Camera Feed]
    F --> G[Display "Press Anywhere to Begin" Prompt]
    G --> H[User Taps Screen]
    H --> I[Start Training Session]
```

## Next Steps
- Implement the loading screen view.
- Modify `OrchestratorView` to manage the loading screen and prompt.
- Update `ARCoordinator` to signal when assets are configured.
- Test the implementation to ensure it works as expected.