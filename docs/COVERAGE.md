# Health data coverage

Source: Open Wearables 0.9.0, commit ff8527a52ad8a96cd1ebe8c19344295c934ae9dc; live server OpenAPI inspected 26 September 2026.

71 reviewed quantity mappings, plus sleep stages and workouts. Runtime availability depends on iPhone/iOS. All available history is queried without a date cutoff. Apple only returns records the user permits; an empty result does not prove permission was granted.

Non-finite numbers (NaN and positive/negative infinity) are quietly omitted from uploads. Valid records in the same page are still sent. Invalid optional workout measurements/events are omitted individually; a workout with invalid duration is skipped. Sent counts include only uploaded records. Pages containing only invalid values advance locally without an empty upload, so invalid data cannot stall history import. The original Apple Health data is never changed.

## Included quantities

| HealthKit type | Upload unit | Scale |
|---|---|---|
| HKQuantityTypeIdentifierHeartRate | count/min | 1 |
| HKQuantityTypeIdentifierRestingHeartRate | count/min | 1 |
| HKQuantityTypeIdentifierHeartRateVariabilitySDNN | ms | 1 |
| HKQuantityTypeIdentifierHeartRateRecoveryOneMinute | count/min | 1 |
| HKQuantityTypeIdentifierWalkingHeartRateAverage | count/min | 1 |
| HKQuantityTypeIdentifierOxygenSaturation | % | 100 |
| HKQuantityTypeIdentifierBloodGlucose | mg/dL | 1 |
| HKQuantityTypeIdentifierBloodPressureSystolic | mmHg | 1 |
| HKQuantityTypeIdentifierBloodPressureDiastolic | mmHg | 1 |
| HKQuantityTypeIdentifierRespiratoryRate | count/min | 1 |
| HKQuantityTypeIdentifierHeight | m | 1 |
| HKQuantityTypeIdentifierBodyMass | kg | 1 |
| HKQuantityTypeIdentifierBodyFatPercentage | % | 1 |
| HKQuantityTypeIdentifierBodyMassIndex | count | 1 |
| HKQuantityTypeIdentifierLeanBodyMass | kg | 1 |
| HKQuantityTypeIdentifierBodyTemperature | degC | 1 |
| HKQuantityTypeIdentifierVO2Max | ml/kg*min | 1 |
| HKQuantityTypeIdentifierSixMinuteWalkTestDistance | m | 1 |
| HKQuantityTypeIdentifierStepCount | count | 1 |
| HKQuantityTypeIdentifierActiveEnergyBurned | kcal | 1 |
| HKQuantityTypeIdentifierBasalEnergyBurned | kcal | 1 |
| HKQuantityTypeIdentifierAppleStandTime | min | 1 |
| HKQuantityTypeIdentifierAppleExerciseTime | min | 1 |
| HKQuantityTypeIdentifierFlightsClimbed | count | 1 |
| HKQuantityTypeIdentifierDistanceWalkingRunning | m | 1 |
| HKQuantityTypeIdentifierDistanceCycling | m | 1 |
| HKQuantityTypeIdentifierDistanceSwimming | m | 1 |
| HKQuantityTypeIdentifierDistanceDownhillSnowSports | m | 1 |
| HKQuantityTypeIdentifierDistancePaddleSports | m | 1 |
| HKQuantityTypeIdentifierDistanceRowing | m | 1 |
| HKQuantityTypeIdentifierDistanceSkatingSports | m | 1 |
| HKQuantityTypeIdentifierDistanceWheelchair | m | 1 |
| HKQuantityTypeIdentifierDistanceCrossCountrySkiing | m | 1 |
| HKQuantityTypeIdentifierWalkingStepLength | m | 1 |
| HKQuantityTypeIdentifierWalkingSpeed | m/s | 1 |
| HKQuantityTypeIdentifierWalkingDoubleSupportPercentage | % | 1 |
| HKQuantityTypeIdentifierWalkingAsymmetryPercentage | % | 1 |
| HKQuantityTypeIdentifierAppleWalkingSteadiness | % | 1 |
| HKQuantityTypeIdentifierStairDescentSpeed | m/s | 1 |
| HKQuantityTypeIdentifierStairAscentSpeed | m/s | 1 |
| HKQuantityTypeIdentifierRunningPower | W | 1 |
| HKQuantityTypeIdentifierRunningSpeed | m/s | 1 |
| HKQuantityTypeIdentifierRunningVerticalOscillation | cm | 1 |
| HKQuantityTypeIdentifierRunningGroundContactTime | ms | 1 |
| HKQuantityTypeIdentifierRunningStrideLength | cm | 1 |
| HKQuantityTypeIdentifierSwimmingStrokeCount | count | 1 |
| HKQuantityTypeIdentifierEnvironmentalAudioExposure | dBASPL | 1 |
| HKQuantityTypeIdentifierHeadphoneAudioExposure | dBASPL | 1 |
| HKQuantityTypeIdentifierEnvironmentalSoundReduction | dBASPL | 1 |
| HKQuantityTypeIdentifierTimeInDaylight | min | 1 |
| HKQuantityTypeIdentifierWorkoutEffortScore | appleEffortScore | 1 |
| HKQuantityTypeIdentifierEstimatedWorkoutEffortScore | appleEffortScore | 1 |
| HKQuantityTypeIdentifierAppleMoveTime | min | 1 |
| HKQuantityTypeIdentifierAppleSleepingWristTemperature | degC | 1 |
| HKQuantityTypeIdentifierForcedVitalCapacity | L | 1 |
| HKQuantityTypeIdentifierForcedExpiratoryVolume1 | L | 1 |
| HKQuantityTypeIdentifierPeakExpiratoryFlowRate | L/min | 1 |
| HKQuantityTypeIdentifierBasalBodyTemperature | degC | 1 |
| HKQuantityTypeIdentifierAppleSleepingBreathingDisturbances | count | 1 |
| HKQuantityTypeIdentifierWaistCircumference | cm | 1 |
| HKQuantityTypeIdentifierNumberOfTimesFallen | count | 1 |
| HKQuantityTypeIdentifierInhalerUsage | count | 1 |
| HKQuantityTypeIdentifierNumberOfAlcoholicBeverages | count | 1 |
| HKQuantityTypeIdentifierUVExposure | count | 1 |
| HKQuantityTypeIdentifierPushCount | count | 1 |
| HKQuantityTypeIdentifierUnderwaterDepth | m | 1 |
| HKQuantityTypeIdentifierWaterTemperature | degC | 1 |
| HKQuantityTypeIdentifierCyclingCadence | count/min | 1 |
| HKQuantityTypeIdentifierCyclingFunctionalThresholdPower | W | 1 |
| HKQuantityTypeIdentifierCyclingPower | W | 1 |
| HKQuantityTypeIdentifierCyclingSpeed | m/s | 1 |

Height and walking step length are sent in meters because this server multiplies them by 100. Body fat and walking ratios stay fractions because the server converts them. Oxygen saturation is sent as percent. Running lengths and waist circumference use centimeters; HRV/contact time use milliseconds.

## Not yet transferable through this server contract

Nutrition and hydration; reproductive and symptom categories; mindfulness; ECG waveforms; audiograms; clinical records; medication records; activity summaries; workout routes/series; characteristics such as date of birth and blood type. These are not requested or presented as synced.

The following mapped quantities are excluded because the installed server uses incompatible or ambiguous dimensions: AtrialFibrillationBurden, BloodAlcoholContent, CrossCountrySkiingSpeed, ElectrodermalActivity, InsulinDelivery, NikeFuel, PaddleSportsSpeed, PeripheralPerfusionIndex, PhysicalEffort, RowingSpeed.

Workout summaries, metadata and events are included; routes and high-frequency workout series are not. Uploaded metadata is preserved in the request but the server may not retain it in normalized tables.

HealthKit deletions are recorded in an on-device journal, not deleted from the server: the SDK ingestion API has no deletion contract.

## Receipt semantics

HTTP 202 with a valid receipt confirms acceptance into the server queue, not completed normalization. UI counters mean records sent, not records verified in the database. Background delivery, real HealthKit coverage, and server ingestion require physical-device testing.
