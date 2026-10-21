"""Rebuild Relay's quantity catalog from the HealthKit SDK headers of the active Xcode.

Run: python3 scripts/build_catalog.py
Every HealthKit quantity type is included. Units come from Apple's header comments, with a few display overrides.
The resulting JSON and docs/COVERAGE.md are checked in; this script is not a build-time dependency.
"""

import json
import pathlib
import re
import subprocess

sdk = subprocess.run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], capture_output=True, text=True, check=True)
header = next(pathlib.Path(sdk.stdout.strip(), "System/Library/Frameworks/HealthKit.framework").rglob("HKTypeIdentifiers.h"))
declared = re.findall(
    r"HKQuantityTypeIdentifier const (HKQuantityTypeIdentifier\w+)\s+API_AVAILABLE\(ios\(([\d.]+)\)[^;]*;\s*//\s*([^,\n]*),\s*([^\n]+)",
    header.read_text(),
)

# Friendlier units where Apple's canonical unit is awkward to read. Values are converted on the iPhone.
UNITS = {
    "HeartRate": "count/min",
    "RespiratoryRate": "count/min",
    "RunningStrideLength": "cm",
    "WaistCircumference": "cm",
    "VO2Max": "ml/kg*min",
    "UVExposure": "count",
    "ElectrodermalActivity": "mcS",
    "DietarySodium": "mg",
    "DietaryCholesterol": "mg",
    "DietaryCaffeine": "mg",
    "DietaryPotassium": "mg",
    "DietaryCalcium": "mg",
    "DietaryIron": "mg",
    "DietaryMagnesium": "mg",
    "DietaryPhosphorus": "mg",
    "DietaryZinc": "mg",
    "DietaryCopper": "mg",
    "DietaryManganese": "mg",
    "DietaryChloride": "mg",
    "DietaryVitaminB6": "mg",
    "DietaryVitaminC": "mg",
    "DietaryVitaminE": "mg",
    "DietaryThiamin": "mg",
    "DietaryRiboflavin": "mg",
    "DietaryNiacin": "mg",
    "DietaryPantothenicAcid": "mg",
    "DietarySelenium": "mcg",
    "DietaryChromium": "mcg",
    "DietaryMolybdenum": "mcg",
    "DietaryIodine": "mcg",
    "DietaryVitaminA": "mcg",
    "DietaryVitaminB12": "mcg",
    "DietaryVitaminD": "mcg",
    "DietaryVitaminK": "mcg",
    "DietaryFolate": "mcg",
    "DietaryBiotin": "mcg",
}
VITALS = ("Heart", "Blood", "Oxygen", "Respiratory", "VitalCapacity", "Expiratory", "Breathing", "AtrialFibrillation",
          "PeripheralPerfusion", "ElectrodermalActivity", "Glucose", "Insulin")
BODY = ("Body", "Height", "Waist", "Mass", "Temperature")
ENVIRONMENT = ("Audio", "Sound", "Daylight", "UV", "WaterTemperature", "Underwater")
OTHER = ("NumberOfTimesFallen", "InhalerUsage", "NumberOfAlcoholicBeverages", "BloodAlcoholContent", "InsulinDelivery")


def group(short: str) -> str:
    if short.startswith("Dietary"):
        return "nutrition"
    if short in OTHER:
        return "other"
    if any(word in short for word in ENVIRONMENT) and short != "BodyTemperature":
        return "environment"
    if any(word in short for word in VITALS):
        return "vitals"
    if any(word in short for word in BODY):
        return "body"
    return "activity"


def title(short: str) -> str:
    words = re.sub(r"([a-z])([A-Z])", r"\1 \2", short.removeprefix("Dietary")).replace("Apple ", "")
    return words.replace("UVExposure", "UV Exposure").replace("SDNN", "(SDNN)").replace("RMSSD", " (RMSSD)").replace("VO2", "VO₂").replace("  ", " ").strip()


rows = []
for identifier, ios, unit, aggregation in declared:
    short = identifier.removeprefix("HKQuantityTypeIdentifier")
    unit = UNITS.get(short, unit.strip())
    rows.append({
        "id": identifier,
        "title": title(short),
        "group": group(short),
        "unit": unit,
        # Fractions become percentages so values read as they do in the Health app.
        "scale": 100 if unit == "%" else 1,
        "aggregation": "cumulative" if aggregation.startswith("Cumulative") else "discrete",
        "ios": ios,
    })
rows.sort(key=lambda row: (row["group"], row["title"]))
pathlib.Path("Relay/Health/Catalog.json").write_text(json.dumps(rows, indent=2, ensure_ascii=False) + "\n")

coverage = [
    "# Health data coverage",
    "",
    f"Relay reads {len(rows)} HealthKit quantity types, sleep stages, mindful sessions, stand hours, heart rate"
    " notifications, workouts and food entries, and sends them to Relay Hub. Generated from the HealthKit SDK headers"
    " by `scripts/build_catalog.py`. Types that need a newer iOS than the device runs are skipped.",
    "",
    "Apple Health only returns records you allow. Empty results can mean no data or no access.",
    "",
    "## Quantity types",
    "",
    "| HealthKit type | Group | Unit sent | Daily statistic |",
    "|---|---|---|---|",
    *[
        f"| {row['id']} | {row['group']} | {row['unit']} | {'sum' if row['aggregation'] == 'cumulative' else 'average, min, max'} |"
        for row in rows
    ],
    "",
    "Percentages are sent as 0–100. Heart and respiratory rates use count/min; stride length and waist"
    " circumference use centimetres.",
    "",
    "## Other records",
    "",
    "- **Sleep stages** (`HKCategoryTypeIdentifierSleepAnalysis`): in bed, asleep, awake, core, deep and REM.",
    "- **Mindful sessions, stand hours and heart rate notifications** (high, low, irregular rhythm), as category samples.",
    "- **Workouts**: activity, duration, active energy, distance, heart rate statistics and workout events."
    " Routes and high-frequency series are not uploaded.",
    "- **Food entries** (`HKCorrelationTypeIdentifierFood`): group the nutrition samples of one meal.",
    "",
    "## Not uploaded",
    "",
    "Clinical records, medications, ECG waveforms, audiograms, reproductive health and symptom categories,"
    " state of mind, workout routes, and characteristics such as date of birth or blood type.",
    "",
    "## Accuracy",
    "",
    "Raw samples keep their HealthKit UUIDs, timestamps, time zones, source apps and devices. Deletions in Apple"
    " Health are sent to Relay Hub. Daily totals come from HealthKit's own statistics, which merge overlapping"
    " sources such as iPhone and Apple Watch, rather than from adding raw samples.",
    "",
]
pathlib.Path("docs/COVERAGE.md").write_text("\n".join(coverage))
print(f"Wrote {len(rows)} quantity types")
