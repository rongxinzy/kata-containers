// Copyright (c) 2017-2018 Intel Corporation
// Copyright (c) 2018 Huawei Corporation
//
// SPDX-License-Identifier: Apache-2.0
//

package drivers

import (
	"testing"

	"github.com/kata-containers/kata-containers/src/runtime/pkg/device/config"
	"github.com/stretchr/testify/assert"
)

func TestGetVFIODetails(t *testing.T) {
	type testData struct {
		deviceStr   string
		expectedStr string
	}

	data := []testData{
		{"0000:02:10.0", "0000:02:10.0"},
		{"0000:0210.0", ""},
		{"f79944e4-5a3d-11e8-99ce-", ""},
		{"f79944e4-5a3d-11e8-99ce", ""},
		{"test", ""},
		{"", ""},
	}

	for _, d := range data {
		deviceBDF, deviceSysfsDev, vfioDeviceType, err := GetVFIODetails(d.deviceStr, "")

		switch vfioDeviceType {
		case config.VFIOPCIDeviceNormalType:
			assert.Equal(t, d.expectedStr, deviceBDF)
		case config.VFIOPCIDeviceMediatedType, config.VFIOAPDeviceMediatedType:
			assert.Equal(t, d.expectedStr, deviceSysfsDev)
		default:
			assert.NotNil(t, err)
		}

		if d.expectedStr == "" {
			assert.NotNil(t, err)
		} else {
			assert.Nil(t, err)
		}
	}

}

func TestGroupVFIODevicesByIOMMUPrefersSysfsGPUClass(t *testing.T) {
	audio := &config.VFIODev{BDF: "0000:01:00.1", Class: "0x040300"}
	gpu := &config.VFIODev{BDF: "0000:02:00.0", Class: "0x030000"}
	usb := &config.VFIODev{BDF: "0000:03:00.0", Class: "0x0c0330"}

	grouped := groupVFIODevicesByIOMMU([]*config.VFIODev{audio, gpu, usb})

	assert.Equal(t, []*config.VFIODev{gpu, audio, usb}, grouped)
	assert.True(t, gpu.IsMultifunction)
	assert.Equal(t, uint8(0), gpu.Function)
	assert.Equal(t, uint8(1), audio.Function)
	assert.Equal(t, uint8(2), usb.Function)
}
