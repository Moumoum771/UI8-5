echo "Adding ARMv8 SDHMS"
ADD_TO_WORK_DIR "$SOURCE_EXTRA_FIRMWARES" "system" "system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk" 0 0 644 "u:object_r:system_file:s0"

echo "Add SM6150 flags on SSRM"

DECODE_APK "system/framework/ssrm.jar"
FTP="
system/framework/ssrm.jar/smali/com/android/server/ssrm/Feature.smali
"
for f in $FTP; do
sed -i "s/\"dvfs_policy_default\"/\"dvfs_policy_sm6150_xx\"/g" "$APKTOOL_DIR/$f"
sed -i "s/siop_a36xq_sm6475/siop_a70q_sm6150/g" "$APKTOOL_DIR/$f"
done

echo "SDHMS was patched successfully!"
