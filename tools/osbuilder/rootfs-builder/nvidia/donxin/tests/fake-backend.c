// SPDX-License-Identifier: Apache-2.0

#include <stdio.h>
#include <string.h>

int main(int argc, char **argv)
{
	printf("program=%s NVIDIA-SMI NVIDIA GeForce RTX 4060 Ti "
	       "NVIDIA GeForce RTX 4060 NVIDIA GeForce RTX 4090 nvidia "
	       "10de:2805\n",
	       argv[0]);
	fprintf(stderr, "stderr=NVIDIA Corporation nvidia_uvm\n");
	for (int i = 1; i < argc; i++)
		printf("arg[%d]=%s\n", i, argv[i]);
	return 7;
}
