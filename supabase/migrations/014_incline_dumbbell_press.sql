-- Forward-only continuation of the applied production history (001-012).
-- Originally authored as 006_incline_dumbbell_press.sql on the camera/referee
-- fork, where it was never applied to production. Renumbered to follow 013
-- rather than rewriting applied history. Behaviour is unchanged.
--
-- Depends only on 002_exercises (applied): public.exercises exists and
-- exercises.name carries a unique constraint, which the upsert below requires.
-- Additive and idempotent — inserts one new catalog row, touches no existing
-- exercise, and re-running it only refreshes this row's own joint_config.
-- Thresholds here mirror the client RepCounter defaults (top 155 degrees,
-- bottom 100 degrees, confidence 0.35, median window 5); keep them in step
-- when gym testing retunes the referee.
--
-- First playable exercise. Keep this separate from generic Bench Press so
-- camera thresholds and history are not mixed across materially different lifts.
insert into public.exercises (name, muscle_group, joint_config, is_active)
values (
  'Incline Dumbbell Press',
  'Chest',
  '{
    "exercise": "Incline Dumbbell Press",
    "camera_angle": "side",
    "primary_joints": ["shoulder", "elbow", "wrist"],
    "body_orientation": "incline_supine",
    "rep_phases": {
      "bottom": { "elbow_angle_max": 100, "description": "Dumbbells at full controlled depth" },
      "top": { "elbow_angle_min": 155, "description": "Arms near lockout" }
    },
    "rom_threshold": {
      "elbow_angle_at_bottom": 100,
      "rule": "elbow_angle must reach <= threshold to count as full ROM"
    },
    "rep_state_machine": {
      "start": "top",
      "sequence": ["top", "bottom", "top"],
      "completion": "reaching top after valid bottom = 1 verified rep"
    },
    "noise_filters": {
      "joint_confidence_threshold": 0.35,
      "median_window_frames": 5
    }
  }'::jsonb,
  true
)
on conflict (name) do update
set joint_config = excluded.joint_config,
    muscle_group = excluded.muscle_group,
    is_active = excluded.is_active;
