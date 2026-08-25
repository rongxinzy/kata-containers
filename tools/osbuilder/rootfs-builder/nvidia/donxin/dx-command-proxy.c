// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DONXIN

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef DONXIN_GPU_QUERY_PATH
#define DONXIN_GPU_QUERY_PATH "/usr/libexec/donxin/gpu-query"
#endif

#ifndef DONXIN_SYSBOX_PATH
#define DONXIN_SYSBOX_PATH "/usr/libexec/donxin/sysbox"
#endif

struct replacement {
	const char *from;
	const char *to;
};

/* Keep specific model names ahead of the generic vendor replacements. */
static const struct replacement smi_replacements[] = {
	{"NVIDIA GeForce RTX 4060 Ti", "DONXIN-8120S"},
	{"NVIDIA GeForce RTX 4060", "DONXIN-8120"},
	{"NVIDIA GeForce RTX 4090", "DONXIN-8140"},
	{"NVIDIA-SMI", "DX-SMI"},
	{"CUDA Version: ", "cuda Version: "},
	{"NVIDIA", "DONXIN"},
	{"nvidia", "donxin"},
};

static const struct replacement pci_replacements[] = {
	{"NVIDIA GeForce RTX 4060 Ti", "DONXIN-8120S"},
	{"NVIDIA GeForce RTX 4060", "DONXIN-8120"},
	{"NVIDIA GeForce RTX 4090", "DONXIN-8140"},
	{"NVIDIA", "DONXIN"},
	{"nvidia", "donxin"},
	/* BusyBox lspci prints numeric vendor IDs instead of pci.ids names. */
	{" 10de:", " DONXIN:"},
	{"\t10de:", "\tDONXIN:"},
};

static const struct replacement module_replacements[] = {
	{"NVIDIA", "DONXIN"},
	{"nvidia", "donxin"},
};

struct filter_state {
	char *pending;
	size_t length;
	size_t capacity;
	const struct replacement *rules;
	size_t rule_count;
	int output_fd;
};

static volatile sig_atomic_t child_pid = -1;

static const char *program_basename(const char *path)
{
	const char *slash = strrchr(path, '/');
	return slash == NULL ? path : slash + 1;
}

static int write_all(int fd, const void *buffer, size_t length)
{
	const char *cursor = buffer;

	while (length > 0) {
		ssize_t written = write(fd, cursor, length);
		if (written < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		cursor += written;
		length -= (size_t)written;
	}

	return 0;
}

static int filter_reserve(struct filter_state *state, size_t extra)
{
	if (state->length + extra <= state->capacity)
		return 0;

	size_t new_capacity = state->capacity == 0 ? 8192 : state->capacity;
	while (new_capacity < state->length + extra)
		new_capacity *= 2;

	char *new_pending = realloc(state->pending, new_capacity);
	if (new_pending == NULL)
		return -1;

	state->pending = new_pending;
	state->capacity = new_capacity;
	return 0;
}

static bool is_incomplete_rule_prefix(const struct filter_state *state,
				      size_t offset)
{
	size_t remaining = state->length - offset;

	for (size_t i = 0; i < state->rule_count; i++) {
		size_t from_length = strlen(state->rules[i].from);
		if (remaining >= from_length)
			continue;
		if (memcmp(state->pending + offset, state->rules[i].from,
			   remaining) == 0)
			return true;
	}

	return false;
}

static int filter_flush(struct filter_state *state, bool final)
{
	size_t consumed = 0;

	while (consumed < state->length) {
		if (!final && is_incomplete_rule_prefix(state, consumed))
			break;

		const struct replacement *matched = NULL;
		for (size_t i = 0; i < state->rule_count; i++) {
			size_t from_length = strlen(state->rules[i].from);
			if (state->length - consumed < from_length)
				continue;
			if (memcmp(state->pending + consumed, state->rules[i].from,
				   from_length) == 0) {
				matched = &state->rules[i];
				break;
			}
		}

		if (matched != NULL) {
			if (write_all(state->output_fd, matched->to,
				      strlen(matched->to)) != 0)
				return -1;
			consumed += strlen(matched->from);
		} else {
			if (write_all(state->output_fd, state->pending + consumed, 1) != 0)
				return -1;
			consumed++;
		}
	}

	if (consumed > 0) {
		memmove(state->pending, state->pending + consumed,
			state->length - consumed);
		state->length -= consumed;
	}

	return 0;
}

static int filter_append(struct filter_state *state, const char *data,
			 size_t length)
{
	if (filter_reserve(state, length) != 0)
		return -1;
	memcpy(state->pending + state->length, data, length);
	state->length += length;
	return filter_flush(state, false);
}

static void forward_signal(int signal_number)
{
	pid_t pid = (pid_t)child_pid;
	if (pid > 0)
		kill(pid, signal_number);
}

static int install_signal_handlers(void)
{
	const int signals[] = {SIGINT, SIGTERM, SIGHUP, SIGQUIT};
	struct sigaction action = {
		.sa_handler = forward_signal,
	};

	sigemptyset(&action.sa_mask);
	for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); i++) {
		if (sigaction(signals[i], &action, NULL) != 0)
			return -1;
	}
	return 0;
}

static char **build_child_argv(int argc, char **argv, const char *argv0)
{
	char **child_argv = calloc((size_t)argc + 1, sizeof(*child_argv));
	if (child_argv == NULL)
		return NULL;

	child_argv[0] = (char *)argv0;
	for (int i = 1; i < argc; i++)
		child_argv[i] = argv[i];
	return child_argv;
}

static int run_filtered(const char *backend, char **child_argv,
			const struct replacement *rules, size_t rule_count)
{
	int stdout_pipe[2];
	int stderr_pipe[2];
	if (pipe(stdout_pipe) != 0) {
		perror("dx-smi: pipe");
		return 125;
	}
	if (pipe(stderr_pipe) != 0) {
		perror("dx-smi: pipe");
		close(stdout_pipe[0]);
		close(stdout_pipe[1]);
		return 125;
	}

	pid_t pid = fork();
	if (pid < 0) {
		perror("dx-smi: fork");
		close(stdout_pipe[0]);
		close(stdout_pipe[1]);
		close(stderr_pipe[0]);
		close(stderr_pipe[1]);
		return 125;
	}

	if (pid == 0) {
		close(stdout_pipe[0]);
		close(stderr_pipe[0]);
		if (dup2(stdout_pipe[1], STDOUT_FILENO) < 0 ||
		    dup2(stderr_pipe[1], STDERR_FILENO) < 0)
			_exit(125);
		close(stdout_pipe[1]);
		close(stderr_pipe[1]);
		execv(backend, child_argv);
		dprintf(STDERR_FILENO, "dx-smi: cannot execute backend: %s\n",
			strerror(errno));
		_exit(127);
	}

	child_pid = pid;
	close(stdout_pipe[1]);
	close(stderr_pipe[1]);

	struct filter_state filters[2] = {
		{.rules = rules, .rule_count = rule_count, .output_fd = STDOUT_FILENO},
		{.rules = rules, .rule_count = rule_count, .output_fd = STDERR_FILENO},
	};
	struct pollfd poll_fds[2] = {
		{.fd = stdout_pipe[0], .events = POLLIN},
		{.fd = stderr_pipe[0], .events = POLLIN},
	};
	int open_streams = 2;
	int filter_error = 0;

	while (open_streams > 0) {
		int poll_result = poll(poll_fds, 2, -1);
		if (poll_result < 0) {
			if (errno == EINTR)
				continue;
			filter_error = 1;
			break;
		}

		for (size_t i = 0; i < 2; i++) {
			if (poll_fds[i].fd < 0 ||
			    !(poll_fds[i].revents & (POLLIN | POLLHUP | POLLERR)))
				continue;

			char buffer[4096];
			ssize_t count = read(poll_fds[i].fd, buffer, sizeof(buffer));
			if (count > 0) {
				if (filter_append(&filters[i], buffer, (size_t)count) != 0)
					filter_error = 1;
			} else if (count == 0) {
				if (filter_flush(&filters[i], true) != 0)
					filter_error = 1;
				close(poll_fds[i].fd);
				poll_fds[i].fd = -1;
				open_streams--;
			} else if (errno != EINTR) {
				filter_error = 1;
				close(poll_fds[i].fd);
				poll_fds[i].fd = -1;
				open_streams--;
			}
		}
	}

	for (size_t i = 0; i < 2; i++) {
		if (poll_fds[i].fd >= 0)
			close(poll_fds[i].fd);
		free(filters[i].pending);
	}

	int status = 0;
	while (waitpid(pid, &status, 0) < 0) {
		if (errno != EINTR) {
			filter_error = 1;
			break;
		}
	}
	child_pid = -1;

	if (filter_error)
		return 125;
	if (WIFEXITED(status))
		return WEXITSTATUS(status);
	if (WIFSIGNALED(status))
		return 128 + WTERMSIG(status);
	return 125;
}

int main(int argc, char **argv)
{
	const char *program = program_basename(argv[0]);
	const char *backend = NULL;
	const char *child_argv0 = NULL;
	const struct replacement *rules = NULL;
	size_t rule_count = 0;
	bool internal_compatibility = false;

	if (strcmp(program, "dx-smi") == 0) {
		backend = DONXIN_GPU_QUERY_PATH;
		child_argv0 = "gpu-query";
		rules = smi_replacements;
		rule_count = sizeof(smi_replacements) / sizeof(smi_replacements[0]);
	} else if (strcmp(program, "nvidia-smi") == 0) {
		/* NVRC uses this guest-only alias. CDI removes it from containers. */
		backend = DONXIN_GPU_QUERY_PATH;
		child_argv0 = "nvidia-smi";
		internal_compatibility = true;
	} else if (strcmp(program, "lspci") == 0) {
		backend = DONXIN_SYSBOX_PATH;
		child_argv0 = "lspci";
		rules = pci_replacements;
		rule_count = sizeof(pci_replacements) / sizeof(pci_replacements[0]);
	} else if (strcmp(program, "lsmod") == 0) {
		backend = DONXIN_SYSBOX_PATH;
		child_argv0 = "lsmod";
		rules = module_replacements;
		rule_count = sizeof(module_replacements) / sizeof(module_replacements[0]);
	} else {
		dprintf(STDERR_FILENO, "donxin command proxy: unsupported name %s\n",
			program);
		return 127;
	}

	char **child_argv = build_child_argv(argc, argv, child_argv0);
	if (child_argv == NULL) {
		perror("dx-smi: arguments");
		return 125;
	}

	if (internal_compatibility) {
		execv(backend, child_argv);
		dprintf(STDERR_FILENO, "nvidia-smi compatibility backend failed: %s\n",
			strerror(errno));
		return 127;
	}

	if (install_signal_handlers() != 0) {
		perror("dx-smi: sigaction");
		return 125;
	}

	int result = run_filtered(backend, child_argv, rules, rule_count);
	free(child_argv);
	return result;
}
