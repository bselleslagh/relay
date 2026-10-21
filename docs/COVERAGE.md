# Health data coverage

Relay reads 121 HealthKit quantity types, sleep stages, mindful sessions, stand hours, heart rate notifications, workouts and food entries, and sends them to Relay Hub. Generated from the HealthKit SDK headers by `scripts/build_catalog.py`. Types that need a newer iOS than the device runs are skipped.

Apple Health only returns records you allow. Empty results can mean no data or no access.

## Quantity types

| HealthKit type | Group | Unit sent | Daily statistic |
|---|---|---|---|
| HKQuantityTypeIdentifierActiveEnergyBurned | activity | kcal | sum |
| HKQuantityTypeIdentifierBasalEnergyBurned | activity | kcal | sum |
| HKQuantityTypeIdentifierCrossCountrySkiingSpeed | activity | m/s | average, min, max |
| HKQuantityTypeIdentifierCyclingCadence | activity | count/min | average, min, max |
| HKQuantityTypeIdentifierCyclingFunctionalThresholdPower | activity | W | average, min, max |
| HKQuantityTypeIdentifierCyclingPower | activity | W | average, min, max |
| HKQuantityTypeIdentifierCyclingSpeed | activity | m/s | average, min, max |
| HKQuantityTypeIdentifierDistanceCrossCountrySkiing | activity | m | sum |
| HKQuantityTypeIdentifierDistanceCycling | activity | m | sum |
| HKQuantityTypeIdentifierDistanceDownhillSnowSports | activity | m | sum |
| HKQuantityTypeIdentifierDistancePaddleSports | activity | m | sum |
| HKQuantityTypeIdentifierDistanceRowing | activity | m | sum |
| HKQuantityTypeIdentifierDistanceSkatingSports | activity | m | sum |
| HKQuantityTypeIdentifierDistanceSwimming | activity | m | sum |
| HKQuantityTypeIdentifierDistanceWalkingRunning | activity | m | sum |
| HKQuantityTypeIdentifierDistanceWheelchair | activity | m | sum |
| HKQuantityTypeIdentifierEstimatedWorkoutEffortScore | activity | appleEffortScore | average, min, max |
| HKQuantityTypeIdentifierAppleExerciseTime | activity | min | sum |
| HKQuantityTypeIdentifierFlightsClimbed | activity | count | sum |
| HKQuantityTypeIdentifierAppleMoveTime | activity | min | sum |
| HKQuantityTypeIdentifierNikeFuel | activity | count | sum |
| HKQuantityTypeIdentifierPaddleSportsSpeed | activity | m/s | average, min, max |
| HKQuantityTypeIdentifierPhysicalEffort | activity | kcal/(kg*hr) | average, min, max |
| HKQuantityTypeIdentifierPushCount | activity | count | sum |
| HKQuantityTypeIdentifierRowingSpeed | activity | m/s | average, min, max |
| HKQuantityTypeIdentifierRunningGroundContactTime | activity | ms | average, min, max |
| HKQuantityTypeIdentifierRunningPower | activity | W | average, min, max |
| HKQuantityTypeIdentifierRunningSpeed | activity | m/s | average, min, max |
| HKQuantityTypeIdentifierRunningStrideLength | activity | cm | average, min, max |
| HKQuantityTypeIdentifierRunningVerticalOscillation | activity | cm | average, min, max |
| HKQuantityTypeIdentifierSixMinuteWalkTestDistance | activity | m | average, min, max |
| HKQuantityTypeIdentifierStairAscentSpeed | activity | m/s | average, min, max |
| HKQuantityTypeIdentifierStairDescentSpeed | activity | m/s | average, min, max |
| HKQuantityTypeIdentifierAppleStandTime | activity | min | sum |
| HKQuantityTypeIdentifierStepCount | activity | count | sum |
| HKQuantityTypeIdentifierSwimmingStrokeCount | activity | count | sum |
| HKQuantityTypeIdentifierVO2Max | activity | ml/kg*min | average, min, max |
| HKQuantityTypeIdentifierWalkingAsymmetryPercentage | activity | % | average, min, max |
| HKQuantityTypeIdentifierWalkingDoubleSupportPercentage | activity | % | average, min, max |
| HKQuantityTypeIdentifierWalkingSpeed | activity | m/s | average, min, max |
| HKQuantityTypeIdentifierAppleWalkingSteadiness | activity | % | average, min, max |
| HKQuantityTypeIdentifierWalkingStepLength | activity | m | average, min, max |
| HKQuantityTypeIdentifierWorkoutEffortScore | activity | appleEffortScore | average, min, max |
| HKQuantityTypeIdentifierBasalBodyTemperature | body | degC | average, min, max |
| HKQuantityTypeIdentifierBodyFatPercentage | body | % | average, min, max |
| HKQuantityTypeIdentifierBodyMass | body | kg | average, min, max |
| HKQuantityTypeIdentifierBodyMassIndex | body | count | average, min, max |
| HKQuantityTypeIdentifierBodyTemperature | body | degC | average, min, max |
| HKQuantityTypeIdentifierHeight | body | m | average, min, max |
| HKQuantityTypeIdentifierLeanBodyMass | body | kg | average, min, max |
| HKQuantityTypeIdentifierAppleSleepingWristTemperature | body | degC | average, min, max |
| HKQuantityTypeIdentifierWaistCircumference | body | cm | average, min, max |
| HKQuantityTypeIdentifierEnvironmentalAudioExposure | environment | dBASPL | average, min, max |
| HKQuantityTypeIdentifierEnvironmentalSoundReduction | environment | dBASPL | average, min, max |
| HKQuantityTypeIdentifierHeadphoneAudioExposure | environment | dBASPL | average, min, max |
| HKQuantityTypeIdentifierTimeInDaylight | environment | min | sum |
| HKQuantityTypeIdentifierUVExposure | environment | count | average, min, max |
| HKQuantityTypeIdentifierUnderwaterDepth | environment | m | average, min, max |
| HKQuantityTypeIdentifierWaterTemperature | environment | degC | average, min, max |
| HKQuantityTypeIdentifierDietaryBiotin | nutrition | mcg | sum |
| HKQuantityTypeIdentifierDietaryCaffeine | nutrition | mg | sum |
| HKQuantityTypeIdentifierDietaryCalcium | nutrition | mg | sum |
| HKQuantityTypeIdentifierDietaryCarbohydrates | nutrition | g | sum |
| HKQuantityTypeIdentifierDietaryChloride | nutrition | mg | sum |
| HKQuantityTypeIdentifierDietaryCholesterol | nutrition | mg | sum |
| HKQuantityTypeIdentifierDietaryChromium | nutrition | mcg | sum |
| HKQuantityTypeIdentifierDietaryCopper | nutrition | mg | sum |
| HKQuantityTypeIdentifierDietaryEnergyConsumed | nutrition | kcal | sum |
| HKQuantityTypeIdentifierDietaryFatMonounsaturated | nutrition | g | sum |
| HKQuantityTypeIdentifierDietaryFatPolyunsaturated | nutrition | g | sum |
| HKQuantityTypeIdentifierDietaryFatSaturated | nutrition | g | sum |
| HKQuantityTypeIdentifierDietaryFatTotal | nutrition | g | sum |
| HKQuantityTypeIdentifierDietaryFiber | nutrition | g | sum |
| HKQuantityTypeIdentifierDietaryFolate | nutrition | mcg | sum |
| HKQuantityTypeIdentifierDietaryIodine | nutrition | mcg | sum |
| HKQuantityTypeIdentifierDietaryIron | nutrition | mg | sum |
| HKQuantityTypeIdentifierDietaryMagnesium | nutrition | mg | sum |
| HKQuantityTypeIdentifierDietaryManganese | nutrition | mg | sum |
| HKQuantityTypeIdentifierDietaryMolybdenum | nutrition | mcg | sum |
| HKQuantityTypeIdentifierDietaryNiacin | nutrition | mg | sum |
| HKQuantityTypeIdentifierDietaryPantothenicAcid | nutrition | mg | sum |
| HKQuantityTypeIdentifierDietaryPhosphorus | nutrition | mg | sum |
| HKQuantityTypeIdentifierDietaryPotassium | nutrition | mg | sum |
| HKQuantityTypeIdentifierDietaryProtein | nutrition | g | sum |
| HKQuantityTypeIdentifierDietaryRiboflavin | nutrition | mg | sum |
| HKQuantityTypeIdentifierDietarySelenium | nutrition | mcg | sum |
| HKQuantityTypeIdentifierDietarySodium | nutrition | mg | sum |
| HKQuantityTypeIdentifierDietarySugar | nutrition | g | sum |
| HKQuantityTypeIdentifierDietaryThiamin | nutrition | mg | sum |
| HKQuantityTypeIdentifierDietaryVitaminA | nutrition | mcg | sum |
| HKQuantityTypeIdentifierDietaryVitaminB12 | nutrition | mcg | sum |
| HKQuantityTypeIdentifierDietaryVitaminB6 | nutrition | mg | sum |
| HKQuantityTypeIdentifierDietaryVitaminC | nutrition | mg | sum |
| HKQuantityTypeIdentifierDietaryVitaminD | nutrition | mcg | sum |
| HKQuantityTypeIdentifierDietaryVitaminE | nutrition | mg | sum |
| HKQuantityTypeIdentifierDietaryVitaminK | nutrition | mcg | sum |
| HKQuantityTypeIdentifierDietaryWater | nutrition | mL | sum |
| HKQuantityTypeIdentifierDietaryZinc | nutrition | mg | sum |
| HKQuantityTypeIdentifierBloodAlcoholContent | other | % | average, min, max |
| HKQuantityTypeIdentifierInhalerUsage | other | count | sum |
| HKQuantityTypeIdentifierInsulinDelivery | other | IU | sum |
| HKQuantityTypeIdentifierNumberOfAlcoholicBeverages | other | count | sum |
| HKQuantityTypeIdentifierNumberOfTimesFallen | other | count | sum |
| HKQuantityTypeIdentifierAtrialFibrillationBurden | vitals | % | average, min, max |
| HKQuantityTypeIdentifierBloodGlucose | vitals | mg/dL | average, min, max |
| HKQuantityTypeIdentifierBloodPressureDiastolic | vitals | mmHg | average, min, max |
| HKQuantityTypeIdentifierBloodPressureSystolic | vitals | mmHg | average, min, max |
| HKQuantityTypeIdentifierElectrodermalActivity | vitals | mcS | average, min, max |
| HKQuantityTypeIdentifierForcedExpiratoryVolume1 | vitals | L | average, min, max |
| HKQuantityTypeIdentifierForcedVitalCapacity | vitals | L | average, min, max |
| HKQuantityTypeIdentifierHeartRate | vitals | count/min | average, min, max |
| HKQuantityTypeIdentifierHeartRateRecoveryOneMinute | vitals | count/min | average, min, max |
| HKQuantityTypeIdentifierHeartRateVariabilityRMSSD | vitals | ms | average, min, max |
| HKQuantityTypeIdentifierHeartRateVariabilitySDNN | vitals | ms | average, min, max |
| HKQuantityTypeIdentifierOxygenSaturation | vitals | % | average, min, max |
| HKQuantityTypeIdentifierPeakExpiratoryFlowRate | vitals | L/min | average, min, max |
| HKQuantityTypeIdentifierPeripheralPerfusionIndex | vitals | % | average, min, max |
| HKQuantityTypeIdentifierRespiratoryRate | vitals | count/min | average, min, max |
| HKQuantityTypeIdentifierRestingHeartRate | vitals | count/min | average, min, max |
| HKQuantityTypeIdentifierAppleSleepingBreathingDisturbances | vitals | count | average, min, max |
| HKQuantityTypeIdentifierWalkingHeartRateAverage | vitals | count/min | average, min, max |

Percentages are sent as 0–100. Heart and respiratory rates use count/min; stride length and waist circumference use centimetres.

## Other records

- **Sleep stages** (`HKCategoryTypeIdentifierSleepAnalysis`): in bed, asleep, awake, core, deep and REM.
- **Mindful sessions, stand hours and heart rate notifications** (high, low, irregular rhythm), as category samples.
- **Workouts**: activity, duration, active energy, distance, heart rate statistics and workout events. Routes and high-frequency series are not uploaded.
- **Food entries** (`HKCorrelationTypeIdentifierFood`): group the nutrition samples of one meal.

## Not uploaded

Clinical records, medications, ECG waveforms, audiograms, reproductive health and symptom categories, state of mind, workout routes, and characteristics such as date of birth or blood type.

## Accuracy

Raw samples keep their HealthKit UUIDs, timestamps, time zones, source apps and devices. Deletions in Apple Health are sent to Relay Hub. Daily totals come from HealthKit's own statistics, which merge overlapping sources such as iPhone and Apple Watch, rather than from adding raw samples.
