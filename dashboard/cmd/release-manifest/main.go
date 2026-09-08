package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"

	"github.com/abdul-mohsen/deployment/dashboard/internal/scripts"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	switch os.Args[1] {
	case "generate":
		if err := generate(os.Args[2:]); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	case "validate":
		if err := validate(os.Args[2:]); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	default:
		usage()
		os.Exit(2)
	}
}

func generate(args []string) error {
	fs := flag.NewFlagSet("generate", flag.ContinueOnError)
	inputPath := fs.String("input", "", "candidate release JSON")
	previousPath := fs.String("previous", "", "previous release JSON")
	outputPath := fs.String("output", "", "output release catalog JSON")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *inputPath == "" || *outputPath == "" {
		return fmt.Errorf("generate requires -input and -output")
	}
	candidate, err := readRelease(*inputPath)
	if err != nil {
		return fmt.Errorf("read input: %w", err)
	}
	var previous *scripts.ReleaseManifest
	if *previousPath != "" {
		value, err := readRelease(*previousPath)
		if err != nil {
			return fmt.Errorf("read previous: %w", err)
		}
		previous = &value
	}
	manifest, err := scripts.GenerateReleaseManifest(candidate, previous)
	if err != nil {
		return err
	}
	file := scripts.ReleaseManifestFile{
		SchemaVersion: scripts.ReleaseManifestSchemaVersion,
		Releases:      []scripts.ReleaseManifest{manifest},
	}
	return writeJSON(*outputPath, file)
}

func validate(args []string) error {
	fs := flag.NewFlagSet("validate", flag.ContinueOnError)
	manifestPath := fs.String("manifest", "", "release catalog JSON")
	dockerHub := fs.Bool("dockerhub", false, "check Docker Hub tag metadata")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *manifestPath == "" {
		return fmt.Errorf("validate requires -manifest")
	}
	manifest, err := readRelease(*manifestPath)
	if err != nil {
		return fmt.Errorf("read manifest: %w", err)
	}
	var resolver scripts.ImageResolver
	if *dockerHub {
		resolver = scripts.DockerHubResolver{}
	}
	validated, result := manifest.Validated(context.Background(), scripts.ValidationOptions{
		Resolver:      resolver,
		RequireRemote: true,
	})
	encoded, _ := json.MarshalIndent(validated, "", "  ")
	fmt.Println(string(encoded))
	if !result.Ready {
		return fmt.Errorf("release is not ready: %v", result.Errors)
	}
	return nil
}

func readRelease(path string) (scripts.ReleaseManifest, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return scripts.ReleaseManifest{}, err
	}
	var release scripts.ReleaseManifest
	if err := json.Unmarshal(data, &release); err == nil && (release.ID != "" || release.Tag != "" || release.Components != nil) {
		return release, nil
	}
	var file scripts.ReleaseManifestFile
	if err := json.Unmarshal(data, &file); err == nil && len(file.Releases) > 0 {
		return file.Releases[0], nil
	}
	var legacy []scripts.ReleaseManifest
	if err := json.Unmarshal(data, &legacy); err == nil && len(legacy) > 0 {
		return legacy[0], nil
	}
	return scripts.ReleaseManifest{}, fmt.Errorf("no release found in %s", path)
}

func writeJSON(path string, value any) error {
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	return os.WriteFile(path, data, 0o600)
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: release-manifest generate -input candidate.json -output releases.json [-previous previous.json]")
	fmt.Fprintln(os.Stderr, "       release-manifest validate -manifest releases.json [-dockerhub]")
}
