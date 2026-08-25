// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DONXIN

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

struct text_file {
	char **lines;
	size_t count;
	size_t capacity;
};

static void free_text_file(struct text_file *text)
{
	for (size_t i = 0; i < text->count; i++)
		free(text->lines[i]);
	free(text->lines);
}

static int append_line(struct text_file *text, const char *line)
{
	if (text->count == text->capacity) {
		size_t new_capacity = text->capacity == 0 ? 128 : text->capacity * 2;
		char **new_lines = realloc(text->lines,
					   new_capacity * sizeof(*new_lines));
		if (new_lines == NULL)
			return -1;
		text->lines = new_lines;
		text->capacity = new_capacity;
	}

	text->lines[text->count] = strdup(line);
	if (text->lines[text->count] == NULL)
		return -1;
	text->count++;
	return 0;
}

static int read_text_file(const char *path, struct text_file *text)
{
	FILE *input = fopen(path, "r");
	if (input == NULL)
		return -1;

	char *line = NULL;
	size_t line_capacity = 0;
	ssize_t line_length;
	while ((line_length = getline(&line, &line_capacity, input)) >= 0) {
		(void)line_length;
		if (append_line(text, line) != 0) {
			free(line);
			fclose(input);
			return -1;
		}
	}

	free(line);
	if (ferror(input)) {
		fclose(input);
		return -1;
	}
	return fclose(input);
}

static size_t indentation(const char *line)
{
	size_t count = 0;
	while (line[count] == ' ')
		count++;
	return count;
}

static const char *trimmed(const char *line)
{
	return line + indentation(line);
}

static bool path_has_basename(const char *value, const char *basename)
{
	size_t value_length = strcspn(value, " \t\r\n");
	const char *last_slash = NULL;
	for (size_t i = 0; i < value_length; i++) {
		if (value[i] == '/')
			last_slash = value + i;
	}
	const char *name = last_slash == NULL ? value : last_slash + 1;
	return (size_t)(value + value_length - name) == strlen(basename) &&
	       strncmp(name, basename, strlen(basename)) == 0;
}

static bool is_nvidia_smi_mount(const char *line)
{
	const char *content = trimmed(line);
	const char prefix[] = "- hostPath:";
	if (strncmp(content, prefix, sizeof(prefix) - 1) != 0)
		return false;
	content += sizeof(prefix) - 1;
	while (*content == ' ' || *content == '\t')
		content++;
	return path_has_basename(content, "nvidia-smi");
}

static bool is_mount_start_at_indent(const char *line, size_t indent)
{
	return indentation(line) == indent &&
	       strncmp(trimmed(line), "- hostPath:", 11) == 0;
}

static bool line_is_blank(const char *line)
{
	return strspn(line, " \t\r\n") == strlen(line);
}

static void write_mount(FILE *output, size_t indent, const char *host_path,
			const char *container_path)
{
	fprintf(output, "%*s- hostPath: %s\n", (int)indent, "", host_path);
	fprintf(output, "%*s  containerPath: %s\n", (int)indent, "",
		container_path);
	fprintf(output, "%*s  options:\n", (int)indent, "");
	const char *options[] = {"ro", "nosuid", "nodev", "rbind", "rprivate"};
	for (size_t i = 0; i < sizeof(options) / sizeof(options[0]); i++)
		fprintf(output, "%*s    - %s\n", (int)indent, "", options[i]);
}

static int write_transformed(const char *path, const struct text_file *text,
			     size_t mount_start, size_t mount_end,
			     size_t mount_indent, mode_t mode)
{
	size_t template_length = strlen(path) + 32;
	char *temporary = malloc(template_length);
	if (temporary == NULL)
		return -1;
	snprintf(temporary, template_length, "%s.donxin.XXXXXX", path);

	int fd = mkstemp(temporary);
	if (fd < 0) {
		free(temporary);
		return -1;
	}
	if (fchmod(fd, mode & 07777) != 0) {
		close(fd);
		unlink(temporary);
		free(temporary);
		return -1;
	}

	FILE *output = fdopen(fd, "w");
	if (output == NULL) {
		close(fd);
		unlink(temporary);
		free(temporary);
		return -1;
	}

	for (size_t i = 0; i < mount_start; i++)
		fputs(text->lines[i], output);

	/* Replace the public nvidia-smi mount with the DONXIN command surface. */
	write_mount(output, mount_indent, "/bin/dx-smi", "/usr/bin/dx-smi");
	write_mount(output, mount_indent, "/usr/libexec/donxin/gpu-query",
		    "/usr/libexec/donxin/gpu-query");
	write_mount(output, mount_indent, "/bin/dx-smi", "/usr/bin/lspci");
	write_mount(output, mount_indent, "/bin/dx-smi", "/usr/bin/lsmod");
	write_mount(output, mount_indent, "/bin/dx-smi", "/usr/sbin/lsmod");
	write_mount(output, mount_indent, "/bin/busybox",
		    "/usr/libexec/donxin/sysbox");

	for (size_t i = mount_end; i < text->count; i++)
		fputs(text->lines[i], output);

	int result = 0;
	if (fflush(output) != 0 || fsync(fd) != 0)
		result = -1;
	if (fclose(output) != 0)
		result = -1;
	if (result == 0 && rename(temporary, path) != 0)
		result = -1;
	if (result != 0)
		unlink(temporary);
	free(temporary);
	return result;
}

int main(int argc, char **argv)
{
	if (argc != 2) {
		fprintf(stderr, "usage: %s CDI_SPEC.yaml\n", argv[0]);
		return 2;
	}

	struct stat metadata;
	if (stat(argv[1], &metadata) != 0) {
		perror("dx-cdi-transform: stat");
		return 1;
	}

	struct text_file text = {0};
	if (read_text_file(argv[1], &text) != 0) {
		perror("dx-cdi-transform: read");
		free_text_file(&text);
		return 1;
	}

	size_t mount_start = text.count;
	for (size_t i = 0; i < text.count; i++) {
		if (is_nvidia_smi_mount(text.lines[i])) {
			if (mount_start != text.count) {
				fprintf(stderr,
					"dx-cdi-transform: multiple nvidia-smi mounts\n");
				free_text_file(&text);
				return 1;
			}
			mount_start = i;
		}
	}

	if (mount_start == text.count) {
		fprintf(stderr,
			"dx-cdi-transform: nvidia-smi mount not found; refusing an unbranded CDI spec\n");
		free_text_file(&text);
		return 1;
	}

	size_t mount_indent = indentation(text.lines[mount_start]);
	size_t mount_end = text.count;
	for (size_t i = mount_start + 1; i < text.count; i++) {
		if (is_mount_start_at_indent(text.lines[i], mount_indent) ||
		    (!line_is_blank(text.lines[i]) &&
		     indentation(text.lines[i]) < mount_indent)) {
			mount_end = i;
			break;
		}
	}

	if (write_transformed(argv[1], &text, mount_start, mount_end,
			      mount_indent, metadata.st_mode) != 0) {
		perror("dx-cdi-transform: write");
		free_text_file(&text);
		return 1;
	}

	free_text_file(&text);
	return 0;
}
